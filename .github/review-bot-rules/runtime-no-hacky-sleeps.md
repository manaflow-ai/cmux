# Runtime No Hacky Sleeps

Scope: TypeScript, JavaScript, shell, and non-Swift runtime scripts. Swift timing and blocking primitives are covered by `swift-blocking-runtime.md`.

Flag fixed delays used as synchronization in production application or runtime code.

Report a failure when the diff introduces or materially expands any of these in non-test code:

- `sleep`, `usleep`, shell `sleep`, `setTimeout`, `setInterval`, timers, polling loops, or fixed backoff used to make lifecycle, focus, rendering, socket, process, filesystem, network, or shared-state readiness appear reliable.
- Delay comments or names such as "give it time", "settle", "wait a bit", "wait for readiness", or "avoid race" without a real event from the owner that knows readiness.
- Retrying, teardown, startup, keepalive, debounce, or handoff logic that depends on elapsed wall-clock time instead of a cancellation-aware scheduler, callback, notification, file descriptor or process event, async sequence, state transition, or explicit completion point.

Allowed cases:

- Deterministic sleeps in tests or explicit test-only scaffolding.
- User-visible animation or progress timing where the timer is purely presentation and not coordination.
- Production retry or timeout logic implemented through a dedicated cancellation-aware abstraction with bounded deadlines and tests, where the delay is part of the product behavior rather than a race repair.
- Existing delay code that the PR does not introduce or worsen.

Do not accept a sleep or fixed delay because it is short, only runs once, or seems to fix a flaky repro. A correct fix names the owner, invariant, and real signal that makes the next state valid.

When reporting, identify the changed delay, the race or lifecycle gap it hides, and the event or owner that should replace it.
