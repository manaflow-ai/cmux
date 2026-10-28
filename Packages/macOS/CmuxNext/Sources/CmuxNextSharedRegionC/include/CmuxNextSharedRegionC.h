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
// Chrome's POSIX region (platform_shared_memory_region_posix.cc) makes a read-only
// region (Chrome on macOS uses Mach memory entries instead); macOS sizes a
// POSIX shm object once, so nobody can shrink it under
// a reader. `count` is more than 0.
int cmux_shared_region_create(const void *bytes, size_t count);

// 1 when the received descriptor `fd` may be mapped: a read-only descriptor
// of a POSIX shm object (proc_pidfdinfo PROC_PIDFDPSHMINFO succeeds only for
// one), whose size xnu fixes at its first ftruncate. A regular file, a
// device or a pipe is 0: the sender could shrink a file under the mapping
// and the read would fault. Chrome on macOS passes a Mach memory entry
// (base/memory/platform_shared_memory_region_apple.cc); this channel is a
// Unix socket, so it passes the shm descriptor and checks its type.
int cmux_shared_region_is_sealed(int fd);

// The Chromium host input ring (ChromiumHostInputRing.swift,
// ChromiumHost/src/chromium_host_input_ring.h).
//
// A read-write, close-on-exec descriptor of an unlinked POSIX shared memory
// object of `count` zero bytes, or -1 (errno set): the ring's region, mapped
// by cmux and by the host it is passed to at spawn. macOS sizes a POSIX shm
// object once, so neither side can shrink it under the other's mapping.
int cmux_input_ring_region_create(size_t count);

// A send right to the doorbell the host checked in under `name`, or 0 when
// none is there. One synchronous message to launchd (bootstrap_look_up):
// call it off the main thread, once per host.
unsigned int cmux_input_ring_doorbell_look_up(const char *name);

// Sends one empty message to `port` with a zero timeout, so it never waits:
// 1 when it was sent or a doorbell already waits (the port's queue limit is
// 1), 0 when the port is dead. The host's reader runs at user-interactive
// QoS itself; the message raises no QoS.
int cmux_input_ring_doorbell_ring(unsigned int port);

// Releases a send right from cmux_input_ring_doorbell_look_up.
void cmux_input_ring_doorbell_release(unsigned int port);

#ifdef __cplusplus
}
#endif
#endif
