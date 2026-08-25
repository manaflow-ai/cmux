#include "CmuxControlSocketAtomicsC.h"

void CmuxControlSocketAtomicPointerInitialize(
    CmuxControlSocketAtomicPointerStorage *storage,
    uintptr_t initialValue
) {
    atomic_init(&storage->value, initialValue);
}

uintptr_t CmuxControlSocketAtomicPointerLoadAcquire(
    const CmuxControlSocketAtomicPointerStorage *storage
) {
    return atomic_load_explicit(&storage->value, memory_order_seq_cst);
}

uintptr_t CmuxControlSocketAtomicPointerExchange(
    CmuxControlSocketAtomicPointerStorage *storage,
    uintptr_t value
) {
    return atomic_exchange_explicit(&storage->value, value, memory_order_seq_cst);
}

void CmuxControlSocketAtomicCounterInitialize(
    CmuxControlSocketAtomicCounterStorage *storage,
    uint64_t initialValue
) {
    atomic_init(&storage->value, initialValue);
}

uint64_t CmuxControlSocketAtomicCounterLoad(
    const CmuxControlSocketAtomicCounterStorage *storage
) {
    return atomic_load_explicit(&storage->value, memory_order_seq_cst);
}

void CmuxControlSocketAtomicCounterIncrement(
    CmuxControlSocketAtomicCounterStorage *storage
) {
    atomic_fetch_add_explicit(&storage->value, 1, memory_order_seq_cst);
}

void CmuxControlSocketAtomicCounterDecrement(
    CmuxControlSocketAtomicCounterStorage *storage
) {
    atomic_fetch_sub_explicit(&storage->value, 1, memory_order_seq_cst);
}
