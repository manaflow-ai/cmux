#ifndef CMUX_FOUNDATION_ATOMICS_C_H
#define CMUX_FOUNDATION_ATOMICS_C_H

#include <stdbool.h>
#include <stdatomic.h>

typedef struct {
    atomic_bool value;
} CmuxAtomicBooleanStorage;

void CmuxAtomicBooleanInitialize(CmuxAtomicBooleanStorage *storage, bool initialValue);
bool CmuxAtomicBooleanLoadRelaxed(const CmuxAtomicBooleanStorage *storage);
bool CmuxAtomicBooleanLoadAcquire(const CmuxAtomicBooleanStorage *storage);
void CmuxAtomicBooleanStoreRelease(CmuxAtomicBooleanStorage *storage, bool value);

#endif
