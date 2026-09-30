#ifndef CMUX_CONTROL_SOCKET_ATOMICS_C_H
#define CMUX_CONTROL_SOCKET_ATOMICS_C_H

#include <stdint.h>
#include <stdatomic.h>

typedef struct {
    _Atomic(uintptr_t) value;
} CmuxControlSocketAtomicPointerStorage;

void CmuxControlSocketAtomicPointerInitialize(
    CmuxControlSocketAtomicPointerStorage *storage,
    uintptr_t initialValue
);
uintptr_t CmuxControlSocketAtomicPointerLoadAcquire(
    const CmuxControlSocketAtomicPointerStorage *storage
);
uintptr_t CmuxControlSocketAtomicPointerExchange(
    CmuxControlSocketAtomicPointerStorage *storage,
    uintptr_t value
);

typedef struct {
    _Atomic(uint64_t) value;
} CmuxControlSocketAtomicCounterStorage;

void CmuxControlSocketAtomicCounterInitialize(
    CmuxControlSocketAtomicCounterStorage *storage,
    uint64_t initialValue
);
uint64_t CmuxControlSocketAtomicCounterLoad(
    const CmuxControlSocketAtomicCounterStorage *storage
);
void CmuxControlSocketAtomicCounterIncrement(
    CmuxControlSocketAtomicCounterStorage *storage
);
void CmuxControlSocketAtomicCounterDecrement(
    CmuxControlSocketAtomicCounterStorage *storage
);

#endif
