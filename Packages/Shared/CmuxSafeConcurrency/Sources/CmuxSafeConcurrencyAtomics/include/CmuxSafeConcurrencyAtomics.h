// The hardware atomic operations CmuxSafeConcurrency's lock-free types need on the macOS 14 / iOS 17 floor,
// where Synchronization.Atomic (macOS 15 / iOS 18) is not available. Each call is one atomic instruction on a
// 64-bit word the caller owns, with the memory ordering in its name, as Chromium's base/atomicops.h wraps
// std::atomic and swift-atomics wraps the same compiler builtins (its _AtomicsShims target). Static inline,
// so a Swift call compiles to the instruction itself.

#ifndef CMUX_SAFE_CONCURRENCY_ATOMICS_H
#define CMUX_SAFE_CONCURRENCY_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

static inline uint64_t cmux_safe_atomic_load_acquire(uint64_t *_Nonnull word) {
    return __atomic_load_n(word, __ATOMIC_ACQUIRE);
}

static inline uint64_t cmux_safe_atomic_load_relaxed(uint64_t *_Nonnull word) {
    return __atomic_load_n(word, __ATOMIC_RELAXED);
}

/// Adds `operand` and returns the value before the add.
static inline uint64_t cmux_safe_atomic_fetch_add_acquire(uint64_t *_Nonnull word, uint64_t operand) {
    return __atomic_fetch_add(word, operand, __ATOMIC_ACQUIRE);
}

/// Adds `operand` and returns the value before the add.
static inline uint64_t cmux_safe_atomic_fetch_add_relaxed(uint64_t *_Nonnull word, uint64_t operand) {
    return __atomic_fetch_add(word, operand, __ATOMIC_RELAXED);
}

/// Subtracts `operand` and returns the value before the subtraction.
static inline uint64_t cmux_safe_atomic_fetch_sub_release(uint64_t *_Nonnull word, uint64_t operand) {
    return __atomic_fetch_sub(word, operand, __ATOMIC_RELEASE);
}

/// Sets the bits of `mask` and returns the value before.
static inline uint64_t cmux_safe_atomic_fetch_or_release(uint64_t *_Nonnull word, uint64_t mask) {
    return __atomic_fetch_or(word, mask, __ATOMIC_RELEASE);
}

/// Stores `desired` when the word holds `expected` (acquire and release on success, acquire on failure);
/// returns whether it stored.
static inline bool cmux_safe_atomic_compare_exchange(uint64_t *_Nonnull word, uint64_t expected, uint64_t desired) {
    return __atomic_compare_exchange_n(word, &expected, desired, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

#endif
