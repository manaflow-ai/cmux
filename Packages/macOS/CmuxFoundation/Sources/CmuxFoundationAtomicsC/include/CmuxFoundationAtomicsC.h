#ifndef CMUX_FOUNDATION_ATOMICS_C_H
#define CMUX_FOUNDATION_ATOMICS_C_H

#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

typedef struct {
    atomic_bool value;
} CmuxAtomicBooleanStorage;

void CmuxAtomicBooleanInitialize(CmuxAtomicBooleanStorage *storage, bool initialValue);
bool CmuxAtomicBooleanLoadRelaxed(const CmuxAtomicBooleanStorage *storage);
bool CmuxAtomicBooleanLoadAcquire(const CmuxAtomicBooleanStorage *storage);
void CmuxAtomicBooleanStoreRelease(CmuxAtomicBooleanStorage *storage, bool value);
bool CmuxAtomicBooleanCompareExchange(
    CmuxAtomicBooleanStorage *storage,
    bool expected,
    bool desired
);

typedef struct {
    _Atomic(uint64_t) value;
} CmuxAtomicUInt64Storage;

void CmuxAtomicUInt64Initialize(CmuxAtomicUInt64Storage *storage, uint64_t initialValue);
uint64_t CmuxAtomicUInt64LoadRelaxed(const CmuxAtomicUInt64Storage *storage);
uint64_t CmuxAtomicUInt64AdvanceRelaxed(CmuxAtomicUInt64Storage *storage);

#endif
