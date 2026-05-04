# Swift Blocking Runtime Primitives

Flag new blocking or timing-based synchronization in application and runtime Swift code.

Report a failure when the diff introduces or materially expands any of these in non-test Swift files:

- `DispatchSemaphore`, `semaphore.wait()`, `DispatchGroup.wait()`, or other thread-blocking waits for async work.
- `Thread.sleep`, `usleep`, `sleep`, `Task.sleep`, `DispatchQueue.asyncAfter`, timers, or polling loops in shipped app/runtime code. Treat these as failures by default, even when the delay is small.
- `DispatchQueue.main.sync`, especially in socket, telemetry, terminal, rendering, focus, or input paths.
- `NSLock`, `pthread_mutex`, or similar manual locking around shared mutable state when an actor or MainActor-isolated model would be the safer shape.

Allowed cases:

- Deterministic sleeps in tests or explicit test-only scaffolding.
- UI animation delays where the delay is visual timing, not synchronization.
- Intentional init-time or passive-callback safety deferrals that use delayed main-queue dispatch to avoid AppKit constraint-pass crashes, when the code documents why a real signal is unavailable.
- Very small lock usage around non-async, low-level platform bridges when an actor cannot be used and the code documents the reason.
- Existing blocking code that the PR does not introduce or worsen.

Do not allow `Task.sleep` in production code just because it is inside an async function. Retry backoff, keepalive loops, readiness waits, delayed dispatch, and polling still need a real cancellation-aware scheduler, timer abstraction, async sequence, callback, notification, or state transition unless the changed code is test-only.

cmux-specific emphasis:

- Typing, terminal rendering, socket telemetry, and focus paths are latency-sensitive. Blocking or sleep-based coordination in these paths should fail CI.
- A fix should wait on a real signal, callback, state transition, actor message, notification, or explicit completion point.

When reporting, identify the changed wait or timing primitive and the real event that should replace it.
