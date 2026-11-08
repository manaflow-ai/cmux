#include "CmuxSimulatorSystem.h"

#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/stat.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "Simulator frame transport requires lock-free 64-bit atomics");
_Static_assert(_Alignof(_Atomic uint64_t) <= 8,
               "Simulator frame transport requires eight-byte atomic alignment");

bool cmux_simulator_atomic_u64_is_lock_free(void) {
    _Atomic uint64_t probe = 0;
    return atomic_is_lock_free(&probe);
}

uint64_t cmux_simulator_atomic_load_u64_acquire(const void *address) {
    const _Atomic uint64_t *value = (const _Atomic uint64_t *)address;
    return atomic_load_explicit(value, memory_order_acquire);
}

uint64_t cmux_simulator_atomic_exchange_u64_acq_rel(void *address,
                                                    uint64_t value) {
    _Atomic uint64_t *target = (_Atomic uint64_t *)address;
    return atomic_exchange_explicit(target, value, memory_order_acq_rel);
}

void cmux_simulator_atomic_store_u64_release(void *address, uint64_t value) {
    _Atomic uint64_t *target = (_Atomic uint64_t *)address;
    atomic_store_explicit(target, value, memory_order_release);
}

void cmux_simulator_atomic_thread_fence_seq_cst(void) {
    atomic_thread_fence(memory_order_seq_cst);
}

int32_t cmux_simulator_shm_open(
    const char *name,
    int32_t flags,
    uint16_t permissions
) {
    return shm_open(name, flags, (mode_t)permissions);
}
