#include "CmuxFoundationAtomicsC.h"

void CmuxAtomicBooleanInitialize(CmuxAtomicBooleanStorage *storage, bool initialValue) {
    atomic_init(&storage->value, initialValue);
}

bool CmuxAtomicBooleanLoadRelaxed(const CmuxAtomicBooleanStorage *storage) {
    return atomic_load_explicit(&storage->value, memory_order_relaxed);
}

bool CmuxAtomicBooleanLoadAcquire(const CmuxAtomicBooleanStorage *storage) {
    return atomic_load_explicit(&storage->value, memory_order_acquire);
}

void CmuxAtomicBooleanStoreRelease(CmuxAtomicBooleanStorage *storage, bool value) {
    atomic_store_explicit(&storage->value, value, memory_order_release);
}

bool CmuxAtomicBooleanCompareExchange(
    CmuxAtomicBooleanStorage *storage,
    bool expected,
    bool desired
) {
    return atomic_compare_exchange_strong_explicit(
        &storage->value,
        &expected,
        desired,
        memory_order_acq_rel,
        memory_order_acquire);
}

void CmuxAtomicUInt64Initialize(CmuxAtomicUInt64Storage *storage, uint64_t initialValue) {
    atomic_init(&storage->value, initialValue);
}

uint64_t CmuxAtomicUInt64LoadRelaxed(const CmuxAtomicUInt64Storage *storage) {
    return atomic_load_explicit(&storage->value, memory_order_relaxed);
}

uint64_t CmuxAtomicUInt64AdvanceRelaxed(CmuxAtomicUInt64Storage *storage) {
    uint64_t current = atomic_load_explicit(&storage->value, memory_order_relaxed);
    while (current != UINT64_MAX) {
        uint64_t next = current + 1;
        if (atomic_compare_exchange_weak_explicit(
                &storage->value,
                &current,
                next,
                memory_order_relaxed,
                memory_order_relaxed)) {
            return next;
        }
    }
    return UINT64_MAX;
}
