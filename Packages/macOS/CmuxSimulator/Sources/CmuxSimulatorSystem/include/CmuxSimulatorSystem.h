#ifndef CMUX_SIMULATOR_SYSTEM_H
#define CMUX_SIMULATOR_SYSTEM_H

#include <stdbool.h>
#include <stdint.h>

bool cmux_simulator_atomic_u64_is_lock_free(void);
uint64_t cmux_simulator_atomic_load_u64_acquire(const void *address);
uint64_t cmux_simulator_atomic_exchange_u64_acq_rel(void *address, uint64_t value);
void cmux_simulator_atomic_store_u64_release(void *address, uint64_t value);
void cmux_simulator_atomic_thread_fence_seq_cst(void);

int32_t cmux_simulator_shm_open(
    const char *name,
    int32_t flags,
    uint16_t permissions
);

#endif
