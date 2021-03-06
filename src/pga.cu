/*
 * pga.cu
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3.0 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU 
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; If not, see <http://www.gnu.org/licenses/>.
 */
#include "pga.h"
#include <stdlib.h>
#include <stdio.h>
#include <cuda_runtime.h>
#include <math.h>
#include <curand.h>
#include <time.h>

#define CCE(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

static curandGenerator_t randGen;

struct population {
	unsigned long size;
	unsigned genome_len;
	gene *_g;
	gene *current_gen;
	gene *next_gen;
	gene *_g2;
	float *score;
	float *rand;
};

struct pga {
	unsigned p_count;
	population_t *populations[MAX_POPULATIONS];
	obj_f objective;
	mutate_f mutate;
	crossover_f crossover;
	unsigned long blocks;
	unsigned long threads;
};

#define SHARED_MEM

#define GET_GENOME(genomes,id,len) (genomes + (id*len))
#define COPY_GENOME(target, source, length) for(int __i = 0; __i < length; ++__i) target[__i] = source[__i];
#define ITERATE_POP_START(p, pop, offset) int __itr = (int)ceil(p->blocks*(float)p->threads); \
for(offset = 0; offset < pop->size; offset += __itr) {
#define ITERATE_POP_END }
#ifdef SHARED_MEM
#define MAX_THREADS 64
#define RUN_KERNEL(kernel, p, pop, ...) int offset;\
ITERATE_POP_START(p, pop, offset) \
kernel<<<p->blocks, p->threads, p->threads*pop->genome_len*sizeof(gene)>>>(offset, __VA_ARGS__); \
ITERATE_POP_END
#else
#define MAX_THREADS 512
#define RUN_KERNEL(kernel, p, pop, ...) int offset;\
ITERATE_POP_START(p, pop, offset) \
kernel<<<p->blocks, p->threads>>>(offset, __VA_ARGS__); \
ITERATE_POP_END
#endif

typedef void (*generate_f)(pga_t *, population_t *);

__global__ void __g_random_generate(int offset, gene *genomes, unsigned genome_len, float *rand, unsigned long p_size) {
	int index = offset + threadIdx.x + blockIdx.x * blockDim.x;
	if (index >= p_size) return;

	COPY_GENOME(GET_GENOME(genomes, index, genome_len), GET_GENOME(rand, index, genome_len), genome_len);	
}

void __random_generate(pga_t * p, population_t *pop) {
	RUN_KERNEL(__g_random_generate, p, pop, pop->current_gen, pop->genome_len, pop->rand, pop->size);

	CCE(cudaPeekAtLastError());
	CCE(cudaDeviceSynchronize());
}

static generate_f population_generators[MAX_POPULATION_TYPE] = {
	__random_generate
};

void __fill_rand(population_t *p) {
	curandGenerateUniform(randGen, p->rand, p->size*p->genome_len);
}

void pga_fill_random_values(pga_t *p, population_t *pop) {
	__fill_rand(pop);
}

void __fill_population(pga_t *pg, population_t *p, enum population_type type) {
	CCE(cudaMalloc((void**)&p->_g, sizeof(gene)*p->genome_len*p->size));	
	CCE(cudaMalloc((void**)&p->_g2, sizeof(gene)*p->genome_len*p->size));
	CCE(cudaMalloc((void**)&p->score, sizeof(float)*p->size));
	CCE(cudaMalloc((void**)&p->rand, sizeof(float)*p->size*p->genome_len));
	
	p->current_gen = p->_g;
	p->next_gen = p->_g2;
	
	__fill_rand(p);
	population_generators[type](pg, p);
}

void __cleanup_population(population_t *p) {
	CCE(cudaFree(p->_g));
	CCE(cudaFree(p->_g2));
	CCE(cudaFree(p->score));
	CCE(cudaFree(p->rand));
}

__device__ void __default_mutate(gene *g, float *rand, unsigned genome_len) {
	float chance = 0.01;
	int gene_to_mutate = rand[0] * genome_len;
	if (rand[1] <= chance) {
		g[gene_to_mutate] = rand[2];
	}
}

__device__ void __default_crossover(gene *p1, gene *p2, gene *c, float *rand, unsigned genome_len) {
	for (int i = 0; i < genome_len; ++i) {
		if (rand[i] > 0.5) {
			c[i] = p1[i];
		} else {
			c[i] = p2[i];
		}
	}
}

__device__ crossover_f __crossover = __default_crossover;
__device__ mutate_f __mutate = __default_mutate;

pga_t *pga_init() {
	pga_t *ret = (pga_t*) malloc(sizeof(pga_t));
	if (ret == NULL) {
		return NULL;
	}
	curandCreateGenerator(&randGen, CURAND_RNG_PSEUDO_DEFAULT);
	curandSetPseudoRandomGeneratorSeed(randGen, time(NULL));
	ret->p_count = 0;

	void *func;
	cudaMemcpyFromSymbol( &func , __mutate , sizeof(mutate_f));
	pga_set_mutate_function(ret, (mutate_f)func);	
	cudaMemcpyFromSymbol( &func , __crossover , sizeof(crossover_f));
	pga_set_crossover_function(ret, (crossover_f)func);
	
	return ret;
}

void pga_deinit(pga_t *p) {
	curandDestroyGenerator(randGen);
	
	int i;
	for (i = 0; i < p->p_count; ++i) {
		__cleanup_population(p->populations[i]);
		free(p->populations[i]);
	}
	free(p);
}

population_t *pga_create_population(pga_t *p, unsigned long size, unsigned genome_len, enum population_type type) {
	population_t *pop = NULL;

	if (p->p_count == MAX_POPULATIONS) {
		return NULL;	
	}
	
	if (genome_len < 4) {
		return NULL;
	}

	pop = (population_t*) malloc(sizeof(population_t));

	if (pop == NULL) {
		return NULL;
	}

	pop->size = size;
	pop->genome_len = genome_len;

	p->populations[p->p_count++] = pop;
	
	p->threads = MAX_THREADS;
	p->blocks = 8;//ceil(size / (float)p->threads);

	__fill_population(p, pop, type);
	return pop;
}

void pga_set_objective_function(pga_t *p, obj_f f) {
	p->objective = f;
}

void pga_set_mutate_function(pga_t *p, mutate_f f) {
	p->mutate = f;
}

void pga_set_crossover_function(pga_t *p, crossover_f f) {
	p->crossover = f;
}

gene *pga_get_best(pga_t *p, population_t *pop) {
	float *host_score = (float*) malloc(sizeof(float)*pop->size);
	cudaMemcpy(host_score, pop->score, sizeof(float)*pop->size, cudaMemcpyDeviceToHost);
	float best = 0;
	int best_id = -1;
	for (int i = 0; i < pop->size; ++i) {
		if (best_id == -1 || best < host_score[i]) {
			best = host_score[i];
			best_id = i;
		}
			
	}
	printf("%f\n", best);
	gene *solution = (gene*) malloc(sizeof(gene)*pop->genome_len);
	
	cudaMemcpy(solution, GET_GENOME(pop->current_gen, best_id, pop->genome_len), sizeof(gene)*pop->genome_len, cudaMemcpyDeviceToHost);
	free(host_score);
	return solution;
}

gene **pga_get_best_top(pga_t *p, population_t *pop, unsigned length) {
	return NULL;
}

gene *pga_get_best_all(pga_t *p) {
	return NULL;
}

gene **pga_get_best_top_all(pga_t *p, unsigned length) {
	return NULL;
}

__global__ void __g_evaluate(int offset, obj_f obj, gene *genomes, float *score, const unsigned long p_size, const int genome_len) {
	int index = offset + threadIdx.x + blockIdx.x * blockDim.x;
	if (index >= p_size) return;
#ifdef SHARED_MEM
	extern __shared__ float shared_genomes[];

	COPY_GENOME(GET_GENOME(shared_genomes, threadIdx.x, genome_len), GET_GENOME(genomes, index, genome_len), genome_len);
	
	score[index] = obj(GET_GENOME(shared_genomes, threadIdx.x, genome_len), genome_len);
#else
	score[index] = obj(GET_GENOME(genomes, index, genome_len), genome_len);
#endif
}

void pga_evaluate(pga_t *p, population_t *pop) {
	RUN_KERNEL(__g_evaluate, p, pop, p->objective, pop->current_gen, 
		pop->score, pop->size, pop->genome_len);
	
	CCE(cudaPeekAtLastError());
	CCE(cudaDeviceSynchronize());
}

void pga_evaluate_all(pga_t *p) {
	for (int i = 0; i < p->p_count; ++i) {
		pga_evaluate(p, p->populations[i]);
	}
}

#define TOURNAMENT_POPULATION 2

__device__ int tournament_selection(float *score, float *rand, int size) {
	int p[TOURNAMENT_POPULATION];
	int i, best = -1;
	for (i = 0; i < TOURNAMENT_POPULATION; ++i) {
		p[i] = rand[i]*(size);
	}
	for (i = 0; i < TOURNAMENT_POPULATION; ++i) {
		if (best == -1 || score[best] < score[p[i]]) {
			best = p[i];
		}
	}
	return best;
}

__global__ void __g_crossover(int offset, crossover_f crossover, gene *newg, gene *oldg, float *score, float *rand, int genome_len, unsigned long p_size) {
	int index = offset + threadIdx.x + blockIdx.x * blockDim.x;
	if (index >= p_size) return;
	
	float *my_rand = rand + (index*genome_len);
#ifdef SHARED_MEM
	extern __shared__ float shared_genomes[];

	COPY_GENOME(GET_GENOME(shared_genomes, threadIdx.x, genome_len), GET_GENOME(newg, index, genome_len), genome_len);
	
	// TODO: figure a way to select genomes from shared memory
	crossover(
		GET_GENOME(oldg, tournament_selection(score, my_rand, p_size), genome_len), 
		GET_GENOME(oldg, tournament_selection(score, my_rand+TOURNAMENT_POPULATION, p_size), genome_len), 
		GET_GENOME(shared_genomes, threadIdx.x, genome_len), my_rand, genome_len);
	
	COPY_GENOME(GET_GENOME(newg, index, genome_len), GET_GENOME(shared_genomes, threadIdx.x, genome_len), genome_len);
#else
	crossover(
		GET_GENOME(oldg, tournament_selection(score, my_rand, p_size), genome_len), 
		GET_GENOME(oldg, tournament_selection(score, my_rand+TOURNAMENT_POPULATION, p_size), genome_len), 
		GET_GENOME(newg, index, genome_len), my_rand, genome_len);	
#endif
}

void pga_crossover(pga_t *p, population_t *pop, enum crossover_selection_type type) {
	RUN_KERNEL(__g_crossover, p, pop, p->crossover, pop->next_gen, 
		pop->current_gen, pop->score, pop->rand, pop->genome_len, pop->size);

	CCE(cudaPeekAtLastError());
	CCE(cudaDeviceSynchronize());
}

void pga_crossover_all(pga_t *p, enum crossover_selection_type type) {
	for (int i = 0; i < p->p_count; ++i) {
		pga_crossover(p, p->populations[i], TOURNAMENT);
	}
}

__global__ void __g_mutate(int offset, mutate_f mutate_func, gene *genomes, float* rand, unsigned long p_size, unsigned genome_len) {
	int index = offset + threadIdx.x + blockIdx.x * blockDim.x;
	if (index >= p_size) return;
#ifdef SHARED_MEM
	extern __shared__ float shared_genomes[];
	
	COPY_GENOME(GET_GENOME(shared_genomes, threadIdx.x, genome_len), GET_GENOME(genomes, index, genome_len), genome_len);

	mutate_func(GET_GENOME(shared_genomes, threadIdx.x, genome_len), rand + (index*genome_len), genome_len);
	
	COPY_GENOME(GET_GENOME(genomes, index, genome_len), GET_GENOME(shared_genomes, threadIdx.x, genome_len), genome_len);
#else
	mutate_func(GET_GENOME(genomes, index, genome_len), rand + (index*genome_len), genome_len);
#endif
}

void pga_mutate(pga_t *p, population_t *pop) {
	RUN_KERNEL(__g_mutate, p, pop, p->mutate, 
		pop->next_gen, pop->rand, pop->size, pop->genome_len);
	CCE(cudaPeekAtLastError());
	CCE(cudaDeviceSynchronize());
}

void pga_mutate_all(pga_t *p) {
	for (int i = 0; i < p->p_count; ++i) {
		pga_mutate(p, p->populations[i]);
	}
}

void pga_swap_generations(pga_t *p, population_t *pop) {
	float *t = pop->next_gen;
	pop->next_gen = pop->current_gen;
	pop->current_gen = t;
}

void pga_migrate(pga_t *p, float pct) {
	//TODO: grzesiu
}

void pga_migrate_between(pga_t *p, population_t *pop_org, population_t *pop_target, float pct) {
	//TODO: grzesiu
}

void pga_run(pga_t *p, unsigned n) {
	if (p->p_count == 0) {
		return;
	}
	
	for (int i = 0; i < n; ++i) {
		pga_fill_random_values(p, p->populations[0]);
		pga_evaluate(p, p->populations[0]);
		pga_crossover(p, p->populations[0], TOURNAMENT);
		pga_mutate(p, p->populations[0]);
		pga_swap_generations(p, p->populations[0]);
		
	}

	pga_evaluate(p, p->populations[0]);
}

void pga_run_islands(pga_t *p, unsigned n, unsigned m, float pct) {
	//TODO: grzesiu	
}