# Test Determinism

Scope: test files only — `cmuxTests/**`, `cmuxUITests/**`, `ios/cmuxUITests/**`, `Packages/**/Tests/**`, `tests/**`, `tests_v2/**`, `web/tests/**`, `webviews/test/**`. Non-test runtime code is covered by `runtime-no-hacky-sleeps.md` and `swift-blocking-runtime.md`; this is their test-code sibling.

This gate enforces two principles:

1. **Invert the time dependency.** A test must not depend on real wall-clock time. Time-driven behavior (timeouts, debounce, retry, animation) is tested by injecting a virtual/fake clock the test advances by hand, never by sleeping for real and hoping.
2. **Assert on causality, not latency.** A correctness test waits ON a real completion signal (callback, resumed continuation, fulfilled expectation, async-stream yield, posted notification, or a deadline-bounded poll of a real state predicate) and asserts a logical invariant. It never waits a fixed duration and never asserts on a measured duration.

Report a failure when the changed test code introduces or materially expands any of these:

- A fixed `sleep`/`usleep`/`Task.sleep`/`setTimeout`/`Thread.sleep`/`time.sleep` used to wait for async readiness before an assertion (the `sleep(0.3); assert` shape that fails on correct code under load).
- An assertion on a measured wall-clock duration, or a hard absolute latency ceiling on shared CI.
- Reading `Date()` / `Date.now` / `CACurrentMediaTime()` / `perf_counter` / `performance.now()` in an assertion.
- Binding a fixed non-zero port, or hitting a live network host instead of a local fake or ephemeral server.
- Asserting an ordered result of an unordered `Set` / `Dictionary` (or equivalent).
- Unseeded randomness feeding an assertion.
- Order-dependence on shared `static` / global / `UserDefaults` / file state that is not reset per test.

Polling is **not** banned, and this distinction is load-bearing: the banned shape is waiting on a CLOCK then asserting (`sleep(0.3); assert`), which fails on correct code under load. ALLOWED is a deadline-bounded poll of a real CONDITION that returns the instant the condition holds and only fails at a generous deadline — the deadline bounds the FAILURE path only, so load can make a pass slower but never turn a pass into a fail. The hierarchy is: (1) await a real signal, (2) inject a virtual clock, (3) deadline-bounded poll of a real predicate as a fallback when you do not own the producer or it emits no event. Where a test must poll because the system exposes no completion signal, that is a flag to ADD a signal (e.g. a wait-until-rendered RPC), not a defect in the test.

Determinism table (hidden input → determinizing move):

- real time / "settle" → await a signal, or a virtual clock, or deadline-poll a real predicate
- timers / deadlines → inject a `Clock` and advance virtually
- scheduler / async ordering → continuation/expectation fulfilled BY the event; `.serialized` suites
- unordered collections → sort, or compare as sets
- randomness → seed or inject the RNG
- shared state (defaults/static/ports/files) → per-test isolated state, reset in `setUp` + `tearDown`, ephemeral ports / temp dirs
- network → local fake / ephemeral server, never a live endpoint
- performance → assert a work-count metric, or best-of-N + relative + NON-BLOCKING; never a hard absolute wall-clock ceiling on shared CI

Allowed cases (do NOT flag these):

- Deterministic test sleeps that are fixed scenario pacing, not waiting on async readiness.
- Deadline-bounded polls of a real predicate that return the instant the condition holds.
- Virtual-clock advances.
- Signal / expectation / continuation / async-stream / notification awaits.
- CI-orchestration sleeps in GitHub Actions workflow or action YAML.

Do not accept a fixed wait because it is short, only runs once, or seems to fix a flaky repro. A correct test names the real completion signal, the virtual clock, or the deadline-bounded predicate that makes the assertion valid.

When reporting, name the hidden input and the determinizing move from the table that the test should adopt.
