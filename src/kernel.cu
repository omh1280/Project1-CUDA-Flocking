#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
glm::vec3 *dev_contiguousPos;
glm::vec3 *dev_contiguousVel;
// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleStartIndices failed!");

  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleEndIndices failed!");

  cudaMalloc((void**)&dev_contiguousPos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_contiguousPos failed!");

  cudaMalloc((void**)&dev_contiguousVel, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_contiguousVel failed!");

  cudaThreadSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO <<<fullBlocksPerGrid, blockSize >>>(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO <<<fullBlocksPerGrid, blockSize >>>(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaThreadSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {

	// Loop through all the other boids
	glm::vec3 ipos = pos[iSelf];

	glm::vec3 v1(0.0f);
	glm::vec3 v2(0.0f);
	glm::vec3 v3(0.0f);
	glm::vec3 com(0.0f);

	float n_count1 = 0.0f;

	for (int i = 0; i < N; ++i) {
		if (i == iSelf)
			continue;

		glm::vec3 b = pos[i];
			
		float l = glm::length(b - ipos);

		// Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
		if (l < rule1Distance) {
			com += b;
			n_count1 += 1.0f;
		}

		// Rule 2: boids try to stay a distance d away from each other

		if (l < rule2Distance) {
			v2 -= b - ipos;
		}

		// Rule 3: boids try to match the speed of surrounding boids

		if (l < rule3Distance) {
			v3 += vel[i];
		}
	}

	if (n_count1 > 0.0f) {
		com /= n_count1;
		v1 = (com - ipos) * rule1Scale;
	}

	v2 *= rule2Scale;

	v3 *= rule3Scale;

	//printf("n_count 1: %f N_count 3: %f", n_count1, n_count3);
	//printf("V1: %f, %f, %f\nV2: %f, %f, %f\nV3: %f, %f, %f\n", v1.x, v1.y, v1.z,
	//	v2.x, v2.y, v2.z, v3.x, v3.y, v3.z);
	
	//printf("Pos: %f, %f, %f Vel: %f, %f, %f\n", ipos.x,
	//	ipos.y, ipos.z, vel[iSelf].x, vel[iSelf].y, vel[iSelf].z);
	
	return v1 + v2 + v3;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	
	if (index >= N)
		return;

	glm::vec3 n_vel = computeVelocityChange(N, index, pos, vel1);
	n_vel += vel1[index];
    // Clamp the speed
	float speed = glm::length(n_vel);
	if (speed > maxSpeed) {
		//printf("Maxspeed!");

		// I think this will work...
		n_vel = glm::normalize(n_vel) * maxSpeed;

	}

    // Record the new velocity 
	vel2[index] = n_vel;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
    // TODO-2.1
    // - Label each boid with the index of its grid cell.
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		glm::vec3 ipos = pos[index];
		
		glm::vec3 cell = (ipos - gridMin) * inverseCellWidth;

		gridIndices[index] = gridIndex3Dto1D((int)floor(cell.x), (int)floor(cell.y),
			(int)floor(cell.z), gridResolution);

		// - Set up a parallel array of integer indices as pointers to the actual
		//   boid data in pos and vel1/vel2
		indices[index] = index;
	}
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		int cell = particleGridIndices[index];
		if (index == 0) {
			gridCellStartIndices[cell] = 0;
		}
		else {
			int p_cell = particleGridIndices[index - 1];
			if (cell != p_cell) {
				gridCellEndIndices[p_cell] = index - 1;
				gridCellStartIndices[cell] = index;
			}
		}
	}
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // x Identify the grid cell that this particle is in
  // x Identify which cells may contain neighbors. This isn't always 8.
  // x For each cell, read the start/end indices in the boid pointer array.
  // x Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // x Clamp the speed change before putting the new speed in vel2
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}

	glm::vec3 ipos = pos[index];

	glm::vec3 cell = (ipos - gridMin) * inverseCellWidth;
	glm::ivec3 icell = glm::round(cell);

	int *neighbors = new int[8];
	int num_neighbors = 0;
	
	neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y, icell.z, gridResolution);

	if (icell.x != 0 && icell.y != 0 && icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y - 1, icell.z - 1, gridResolution);
	}

	if (icell.x != 0 && icell.y != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y - 1, icell.z, gridResolution);
	}

	if (icell.x != 0 && icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y, icell.z - 1, gridResolution);
	}

	if (icell.y != 0 && icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y - 1, icell.z - 1, gridResolution);
	}

	if (icell.x != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y, icell.z, gridResolution);
	}
	
	if (icell.y != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y - 1, icell.z, gridResolution);
	}

	if (icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y, icell.z - 1, gridResolution);
	}

	glm::vec3 n_vel = vel1[index];

	glm::vec3 v1(0.0f);
	glm::vec3 v2(0.0f);
	glm::vec3 v3(0.0f);
	glm::vec3 com(0.0f);
	float n_count1 = 0.0f;
	if (num_neighbors < 8) 
		printf("Num_neighbors: %i\n", num_neighbors);
	//if (icell.x > 20 || icell.y > 20 || icell.z > 20)
	//	printf("Cell x: %i y: %i z: %i\n", icell.x, icell.y, icell.z);
	// Loop through neighboring cells
	for (int i = 0; i < num_neighbors; i++) {
		int search = neighbors[i];

		int start = gridCellStartIndices[search];
		
		// If cell contains boids
		if (start >= 0) {
			int end = gridCellEndIndices[search];
			//printf("NumCells: %i Start %i End %i\n", gridResolution*gridResolution*gridResolution, start, end);
			// Loop through boids in cell
			while (start <= end) {

				glm::vec3 b = pos[particleArrayIndices[start]];

				float l = glm::length(b - ipos);

				// Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
				if (l < rule1Distance) {
					com += b;
					n_count1 += 1.0f;
				}

				// Rule 2: boids try to stay a distance d away from each other

				if (l < rule2Distance) {
					v2 -= b - ipos;
				}

				// Rule 3: boids try to match the speed of surrounding boids

				if (l < rule3Distance) {
					v3 += vel1[particleArrayIndices[start]];
				}

				start++;
			}
		}
	}

	delete[] neighbors;

	if (n_count1 > 0.0f) {
		com /= n_count1;
		v1 = (com - ipos) * rule1Scale;
	}

	v2 *= rule2Scale;

	v3 *= rule3Scale;

	//printf("n_count 1: %f N_count 3: %f", n_count1, n_count3);
	//printf("V1: %f, %f, %f\nV2: %f, %f, %f\nV3: %f, %f, %f\n", v1.x, v1.y, v1.z,
	//	v2.x, v2.y, v2.z, v3.x, v3.y, v3.z);

	//printf("Pos: %f, %f, %f Vel: %f, %f, %f\n", ipos.x,
	//	ipos.y, ipos.z, vel[iSelf].x, vel[iSelf].y, vel[iSelf].z);

	n_vel += v1 + v2 + v3;

	// Clamp the speed
	float speed = glm::length(n_vel);
	if (speed > maxSpeed) {
		//printf("Maxspeed!");

		n_vel = glm::normalize(n_vel) * maxSpeed;
	}

	// Record the new velocity 
	vel2[index] = n_vel;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // x Identify the grid cell that this particle is in
  // x Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2

	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}

	glm::vec3 ipos = pos[index];

	glm::vec3 cell = (ipos - gridMin) * inverseCellWidth;
	glm::ivec3 icell = glm::round(cell);

	int *neighbors = new int[8];
	int num_neighbors = 0;

	neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y, icell.z, gridResolution);

	if (icell.x != 0 && icell.y != 0 && icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y - 1, icell.z - 1, gridResolution);
	}

	if (icell.x != 0 && icell.y != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y - 1, icell.z, gridResolution);
	}

	if (icell.x != 0 && icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y, icell.z - 1, gridResolution);
	}

	if (icell.y != 0 && icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y - 1, icell.z - 1, gridResolution);
	}

	if (icell.x != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x - 1, icell.y, icell.z, gridResolution);
	}

	if (icell.y != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y - 1, icell.z, gridResolution);
	}

	if (icell.z != 0) {
		neighbors[num_neighbors++] = gridIndex3Dto1D(icell.x, icell.y, icell.z - 1, gridResolution);
	}

	glm::vec3 n_vel = vel1[index];

	glm::vec3 v1(0.0f);
	glm::vec3 v2(0.0f);
	glm::vec3 v3(0.0f);
	glm::vec3 com(0.0f);
	float n_count1 = 0.0f;

	// Loop through neighboring cells
	for (int i = 0; i < num_neighbors; i++) {
		int search = neighbors[i];

		int start = gridCellStartIndices[search];

		// If cell contains boids
		if (start >= 0) {
			int end = gridCellEndIndices[search];
			//printf("NumCells: %i Start %i End %i\n", gridResolution*gridResolution*gridResolution, start, end);
			// Loop through boids in cell
			while (start <= end) {

				glm::vec3 b = pos[start];

				float l = glm::length(b - ipos);

				// Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
				if (l < rule1Distance) {
					com += b;
					n_count1 += 1.0f;
				}

				// Rule 2: boids try to stay a distance d away from each other

				if (l < rule2Distance) {
					v2 -= b - ipos;
				}

				// Rule 3: boids try to match the speed of surrounding boids

				if (l < rule3Distance) {
					v3 += vel1[start];
				}

				start++;
			}
		}
	}

	delete[] neighbors;

	if (n_count1 > 0.0f) {
		com /= n_count1;
		v1 = (com - ipos) * rule1Scale;
	}

	v2 *= rule2Scale;

	v3 *= rule3Scale;

	//printf("n_count 1: %f N_count 3: %f", n_count1, n_count3);
	//printf("V1: %f, %f, %f\nV2: %f, %f, %f\nV3: %f, %f, %f\n", v1.x, v1.y, v1.z,
	//	v2.x, v2.y, v2.z, v3.x, v3.y, v3.z);

	//printf("Pos: %f, %f, %f Vel: %f, %f, %f\n", ipos.x,
	//	ipos.y, ipos.z, vel[iSelf].x, vel[iSelf].y, vel[iSelf].z);

	n_vel += v1 + v2 + v3;

	// Clamp the speed
	float speed = glm::length(n_vel);
	if (speed > maxSpeed) {
		//printf("Maxspeed!");

		n_vel = glm::normalize(n_vel) * maxSpeed;
	}

	// Record the new velocity 
	vel2[index] = n_vel;
}

// Kernel to put boid data in coherentVel and coherentPos such that 
// it is contiguous
__global__ void kernMakeCoherent(int N, int *arrayIndices, glm::vec3 *pos, 
	glm::vec3 *vel,	glm::vec3 *coherentPos, glm::vec3 *coherentVel) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		int boid_index = arrayIndices[index];

		coherentPos[index] = pos[boid_index];
		coherentVel[index] = vel[boid_index];
	}
}

__global__ void kernRestore(int N, int *coherentIndices, glm::vec3 *coherentPos, 
	glm::vec3 *coherentVel, glm::vec3 *pos, glm::vec3 *vel) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		int boid_index = coherentIndices[index];

		pos[boid_index] = coherentPos[index];
		vel[boid_index] = coherentVel[index];
	}
}
/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	
	kernUpdateVelocityBruteForce <<< fullBlocksPerGrid, threadsPerBlock >>>(numObjects, dev_pos,
		dev_vel1, dev_vel2);

	kernUpdatePos<<< fullBlocksPerGrid, threadsPerBlock >>>(numObjects, dt, dev_pos, dev_vel2);

	glm::vec3 *swap = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = swap;
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // x label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  // x Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // x Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // x Perform velocity updates using neighbor search
  // x Update positions
  // x Ping-pong buffers as needed
	dim3 fullBlocksPerGridBoid((numObjects + blockSize - 1) / blockSize);
	dim3 fullBlocksPerGridCell((gridCellCount + blockSize - 1) / blockSize);

	// Compute indices
	// # = numObjects
	kernComputeIndices <<< fullBlocksPerGridBoid, threadsPerBlock >>>(numObjects,
		gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
		dev_particleArrayIndices, dev_particleGridIndices);

	// Thrust sort
	dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		dev_thrust_particleArrayIndices);

	// Reset gridstartindices and endindices
	// # = gridCellCount
	kernResetIntBuffer<<<fullBlocksPerGridCell, threadsPerBlock>>>(gridCellCount, 
		dev_gridCellStartIndices, -1);
	kernResetIntBuffer<<<fullBlocksPerGridCell, threadsPerBlock>>>(gridCellCount,
		dev_gridCellEndIndices, -1);

	// Identify start/end
	// # = numObjects
	kernIdentifyCellStartEnd <<< fullBlocksPerGridBoid, threadsPerBlock >>> (numObjects,
		dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);

	// Update velocities
	// # = numObjects
	kernUpdateVelNeighborSearchScattered<<<fullBlocksPerGridBoid, threadsPerBlock>>>(numObjects,
		gridSideCount, gridMinimum,	gridInverseCellWidth, gridCellWidth, dev_gridCellStartIndices, 
		dev_gridCellEndIndices,	dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);

	// Update positions
	// # = numObjects
	kernUpdatePos <<< fullBlocksPerGridBoid, threadsPerBlock >>>(numObjects, dt, dev_pos, dev_vel2);

	glm::vec3 *swap = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = swap;
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // x Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // x Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // x Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // x BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // x Perform velocity updates using neighbor search
  // x Update positions
  // x Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.

	dim3 fullBlocksPerGridBoid((numObjects + blockSize - 1) / blockSize);
	dim3 fullBlocksPerGridCell((gridCellCount + blockSize - 1) / blockSize);

	// Compute indices
	// # = numObjects
	kernComputeIndices << < fullBlocksPerGridBoid, threadsPerBlock >> >(numObjects,
		gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
		dev_particleArrayIndices, dev_particleGridIndices);

	// Thrust sort
	dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		dev_thrust_particleArrayIndices);

	// Reset gridstartindices and endindices
	// # = gridCellCount
	kernResetIntBuffer << <fullBlocksPerGridCell, threadsPerBlock >> >(gridCellCount,
		dev_gridCellStartIndices, -1);
	kernResetIntBuffer << <fullBlocksPerGridCell, threadsPerBlock >> >(gridCellCount,
		dev_gridCellEndIndices, -1);

	// Identify start/end
	// # = numObjects
	kernIdentifyCellStartEnd << < fullBlocksPerGridBoid, threadsPerBlock >> > (numObjects,
		dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);

	// Move boid data to coherent memory
	kernMakeCoherent << < fullBlocksPerGridBoid, threadsPerBlock >> >(numObjects, dev_particleArrayIndices,
		dev_pos, dev_vel1, dev_contiguousPos, dev_contiguousVel);

	// Update velocities
	// # = numObjects
	kernUpdateVelNeighborSearchCoherent << <fullBlocksPerGridBoid, threadsPerBlock >> >(numObjects,
		gridSideCount, gridMinimum, gridInverseCellWidth, gridCellWidth, dev_gridCellStartIndices,
		dev_gridCellEndIndices, dev_contiguousPos, dev_contiguousVel, dev_vel2);

	// Update positions
	// # = numObjects
	kernUpdatePos << < fullBlocksPerGridBoid, threadsPerBlock >> >(numObjects, dt, 
		dev_contiguousPos, dev_vel2);

	// Restore arrays and swap
	kernRestore << <fullBlocksPerGridBoid, threadsPerBlock >> >(numObjects, dev_particleArrayIndices,
		dev_contiguousPos, dev_vel2, dev_pos, dev_vel1);

}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
  cudaFree(dev_contiguousPos);
  cudaFree(dev_contiguousVel);
  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  int *intKeys = new int[N];
  int *intValues = new int[N];

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys, sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues, sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys, dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues, dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  delete[] intKeys;
  delete[] intValues;
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
