#include "ctranslate2/primitives/gpu_cuda.h"

#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <thrust/device_vector.h>

namespace ctranslate2 {

  static std::string cublasGetStatusString(cublasStatus_t status)
  {
    switch (status)
    {
    case CUBLAS_STATUS_SUCCESS:
      return "CUBLAS_STATUS_SUCCESS";
    case CUBLAS_STATUS_NOT_INITIALIZED:
      return "CUBLAS_STATUS_NOT_INITIALIZED";
    case CUBLAS_STATUS_ALLOC_FAILED:
      return "CUBLAS_STATUS_ALLOC_FAILED";
    case CUBLAS_STATUS_INVALID_VALUE:
      return "CUBLAS_STATUS_INVALID_VALUE";
    case CUBLAS_STATUS_ARCH_MISMATCH:
      return "CUBLAS_STATUS_ARCH_MISMATCH";
    case CUBLAS_STATUS_MAPPING_ERROR:
      return "CUBLAS_STATUS_MAPPING_ERROR";
    case CUBLAS_STATUS_EXECUTION_FAILED:
      return "CUBLAS_STATUS_EXECUTION_FAILED";
    case CUBLAS_STATUS_INTERNAL_ERROR:
      return "CUBLAS_STATUS_INTERNAL_ERROR";
    case CUBLAS_STATUS_NOT_SUPPORTED:
      return "CUBLAS_STATUS_NOT_SUPPORTED";
    case CUBLAS_STATUS_LICENSE_ERROR:
      return "CUBLAS_STATUS_LICENSE_ERROR";
    default:
      return "UNKNOWN";
    }
  }

  static inline void cudaAssert(cudaError_t code, const std::string& file, int line)
  {
    if (code != cudaSuccess)
      throw std::runtime_error("CUDA failed with error '"
                               + std::string(cudaGetErrorString(code))
                               + "' at " + file + ":" + std::to_string(line));
  }

  static inline void cublasAssert(cublasStatus_t status, const std::string& file, int line)
  {
    if (status != CUBLAS_STATUS_SUCCESS)
      throw std::runtime_error("cuBLAS failed with status '"
                               + cublasGetStatusString(status)
                               + "' at " + file + ":" + std::to_string(line));
  }

#define CUDA_CHECK(ans) { cudaAssert((ans), __FILE__, __LINE__); }
#define CUBLAS_CHECK(ans) { cublasAssert((ans), __FILE__, __LINE__); }

  static cudaStream_t& get_cuda_stream() {
    // Use one CUDA stream per host thread.
    static thread_local cudaStream_t stream;
    static thread_local bool initialized = false;
    if (!initialized) {
      CUDA_CHECK(cudaStreamCreate(&stream));
      initialized = true;
    }
    return stream;
  }

  static cublasHandle_t& get_cublas_handle() {
    // Use one cuBLAS handle per host thread.
    static thread_local cublasHandle_t handle;
    static thread_local bool initialized = false;
    if (!initialized) {
      CUBLAS_CHECK(cublasCreate(&handle));
      CUBLAS_CHECK(cublasSetStream(handle, get_cuda_stream()));
      initialized = true;
    }
    return handle;
  }


  template<>
  void* primitives<Device::CUDA>::alloc_data(size_t size) {
    void* data = nullptr;
    CUDA_CHECK(cudaMalloc(&data, size));
    return data;
  }

  template<>
  void primitives<Device::CUDA>::free_data(void* data) {
    CUDA_CHECK(cudaFree(data));
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::fill(T* x, T a, size_t size) {
    thrust::fill_n(thrust::cuda::par.on(get_cuda_stream()), x, size, a);
  }

  template<>
  template <typename T>
  void primitives<Device::CUDA>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T),
                               cudaMemcpyDeviceToDevice, get_cuda_stream()));
  }

  template<>
  template<>
  void primitives<Device::CUDA>::gemm(const float* a, const float* b,
                                      bool transpose_a, bool transpose_b,
                                      size_t m, size_t n, size_t k,
                                      float alpha, float beta,
                                      float* c) {
    // Memo: cuBLAS assumes column-major storage.

    const int lda = transpose_a ? m : k;
    const int ldb = transpose_b ? k : n;
    const int ldc = n;

    const cublasOperation_t transa = transpose_a ? CUBLAS_OP_T : CUBLAS_OP_N;
    const cublasOperation_t transb = transpose_b ? CUBLAS_OP_T : CUBLAS_OP_N;

    CUBLAS_CHECK(cublasSgemm(get_cublas_handle(),
                             transb, transa,
                             n, m, k,
                             &alpha,
                             b, ldb,
                             a, lda,
                             &beta,
                             c, ldc));
  }

  template<>
  template<>
  void primitives<Device::CUDA>::gemm_batch(const float* a, const float* b,
                                            bool transpose_a, bool transpose_b,
                                            size_t batch_size,
                                            size_t m, size_t n, size_t k,
                                            float alpha, float beta,
                                            float* c) {
    // Memo: cuBLAS assumes column-major storage.

    const int lda = transpose_a ? m : k;
    const int ldb = transpose_b ? k : n;
    const int ldc = n;

    const cublasOperation_t transa = transpose_a ? CUBLAS_OP_T : CUBLAS_OP_N;
    const cublasOperation_t transb = transpose_b ? CUBLAS_OP_T : CUBLAS_OP_N;

    const float** a_array = new const float*[batch_size];
    const float** b_array = new const float*[batch_size];
    float** c_array = new float*[batch_size];

    for (size_t i = 0; i < batch_size; ++i) {
      a_array[i] = a + (i * m * k);
      b_array[i] = b + (i * k * n);
      c_array[i] = c + (i * m * n);
    }

    static thread_local const float** a_array_device = nullptr;
    static thread_local const float** b_array_device = nullptr;
    static thread_local float** c_array_device = nullptr;
    static thread_local size_t alloc_size = 0;

    const size_t array_size = batch_size * sizeof (float*);

    if (array_size > alloc_size) {
      CUDA_CHECK(cudaFree(a_array_device));
      CUDA_CHECK(cudaFree(b_array_device));
      CUDA_CHECK(cudaFree(c_array_device));
      CUDA_CHECK(cudaMalloc(&a_array_device, array_size));
      CUDA_CHECK(cudaMalloc(&b_array_device, array_size));
      CUDA_CHECK(cudaMalloc(&c_array_device, array_size));
      alloc_size = array_size;
    }

    cross_device_primitives<Device::CPU, Device::CUDA>::copy(a_array, a_array_device, batch_size);
    cross_device_primitives<Device::CPU, Device::CUDA>::copy(b_array, b_array_device, batch_size);
    cross_device_primitives<Device::CPU, Device::CUDA>::copy(c_array, c_array_device, batch_size);

    delete [] a_array;
    delete [] b_array;
    delete [] c_array;

    CUBLAS_CHECK(cublasSgemmBatched(get_cublas_handle(),
                                    transb, transa,
                                    n, m, k,
                                    &alpha,
                                    b_array_device, ldb,
                                    a_array_device, lda,
                                    &beta,
                                    c_array_device, ldc,
                                    batch_size));
  }


  template<>
  template <typename T>
  void cross_device_primitives<Device::CPU, Device::CUDA>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T), cudaMemcpyHostToDevice, get_cuda_stream()));
  }

  template<>
  template <typename T>
  void cross_device_primitives<Device::CUDA, Device::CPU>::copy(const T* x, T* y, size_t size) {
    CUDA_CHECK(cudaMemcpyAsync(y, x, size * sizeof (T), cudaMemcpyDeviceToHost, get_cuda_stream()));
  }

#define DECLARE_IMPL(T)                                                 \
  template void                                                         \
  primitives<Device::CUDA>::fill(T* x, T a, size_t size);               \
  template void                                                         \
  primitives<Device::CUDA>::copy<T>(const T* x, T* y, size_t size);     \
  template void                                                         \
  cross_device_primitives<Device::CPU, Device::CUDA>::copy<T>(const T*, T*, size_t); \
  template void                                                         \
  cross_device_primitives<Device::CUDA, Device::CPU>::copy<T>(const T*, T*, size_t);

  DECLARE_IMPL(signed char)
  DECLARE_IMPL(float)
  DECLARE_IMPL(int)
  DECLARE_IMPL(short)

}
