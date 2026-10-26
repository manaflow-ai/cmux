#ifndef CMUX_NEXT_SHARED_REGION_C_H_
#define CMUX_NEXT_SHARED_REGION_C_H_
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// A sealed shared memory region for the Chromium host control channel's large
// payloads (plans/cmux-next/chrome-parity/p01-process.md, task 020). Swift
// cannot call shm_open, which is variadic; this is the C side of
// ChromiumHostSharedRegion.swift and the same as CreateSharedRegion in
// ChromiumHost/src/chromium_host_control.cc.
//
// Returns a read-only, close-on-exec descriptor of a POSIX shared memory
// object holding the `count` bytes at `bytes`, or -1 (errno set). The object
// is unlinked before this returns and its writable descriptor is closed, as
// base/memory/platform_shared_memory_region_posix.cc makes a read-only
// region; macOS sizes a POSIX shm object once, so nobody can shrink it under
// a reader. `count` is more than 0.
int cmux_shared_region_create(const void *bytes, size_t count);

#ifdef __cplusplus
}
#endif
#endif
