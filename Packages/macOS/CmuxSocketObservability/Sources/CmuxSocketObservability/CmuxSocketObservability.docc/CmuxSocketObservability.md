# ``CmuxSocketObservability``

Release-visible slow-command observations and bounded main-thread hang diagnostics.

## Overview

The app constructs ``SocketCommandDescriptor`` once from the authorized method and
execution policy. ``SlowSocketCommandReporter`` forwards commands lasting at least
100 milliseconds to an injected ``SlowSocketCommandSink``. Descriptors contain no
request parameters or response payloads.

``MainThreadSocketCommandWatchdog`` monitors only a contiguous synchronous command
body on the main actor. Queue waits, asynchronous readiness waits, preparation, and
worker-side response encoding remain outside that scope. A one-shot Dispatch timer
runs on a separate utility queue, independent of the blocked main actor and the
cooperative task executor. Completion cancels it; the ticket serializes only the
short synchronous timer/completion state transitions, not command execution.

``MainThreadSocketCommandBacktraceCapturer`` never explicitly suspends the target
thread. It obtains a register snapshot with `thread_get_state`, whose temporary
thread hold is owned and released inside the kernel, and walks frame records with
`mach_vm_read_overwrite`. No caller-owned suspend count can leak on error, and
there is no suspended thread holding a lock needed by Swift allocations or symbol
resolution. The C walker uses preallocated storage and is bounded to 128 frames;
unreadable, unaligned, or non-monotonic frames terminate the walk. A running thread
may change its stack between reads, so the backtrace is explicitly best-effort,
not an atomic stack snapshot. Pointer-authentication bits are removed before
symbolication on arm64. The sampler rejects calls targeting its own thread.

The app supplies unified-log and Sentry adapters. Tests exercise the state machine
without an app host and sample a real worker to verify capture and continued execution.

## Tagged runtime verification

DEBUG builds provide bounded fault-injection probes through the authenticated
socket. `debug.socket_command_probe` deliberately parks the main thread for
`delay_ms` (default 1200, clamped to 0...2000) to verify hang, backtrace, recovery,
and slow-command records. `debug.socket_command_sync_probe` runs the legacy
synchronous dispatcher inside the async socket path; `protocol: "v1"` selects
`debug_socket_command_probe`, otherwise it selects the v2 probe. These probes do
not exist in Release builds, mutate no UI, and never activate or focus the app.
The blocking delay is the test stimulus, not a production synchronization path.

## Topics

### Slow commands

- ``SocketCommandDescriptor``
- ``SocketCommandObservation``
- ``SlowSocketCommandReporter``
- ``SlowSocketCommandSink``

### Main-thread watchdog

- ``MainThreadSocketCommandWatchdog``
- ``MainThreadSocketCommandWatchdogObservation``
- ``MainThreadSocketCommandWatchdogReporter``
- ``SocketCommandBacktraceCapturing``
- ``MainThreadSocketCommandBacktraceCapturer``
