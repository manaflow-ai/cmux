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
