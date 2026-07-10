#include "include/CEFKitShims.h"

void cefkit_atomic_store(int32_t *ptr, int32_t value) {
  __atomic_store_n(ptr, value, __ATOMIC_SEQ_CST);
}

int32_t cefkit_atomic_add(int32_t *ptr, int32_t delta) {
  return __atomic_add_fetch(ptr, delta, __ATOMIC_SEQ_CST);
}

int32_t cefkit_atomic_load(int32_t *ptr) {
  return __atomic_load_n(ptr, __ATOMIC_SEQ_CST);
}
