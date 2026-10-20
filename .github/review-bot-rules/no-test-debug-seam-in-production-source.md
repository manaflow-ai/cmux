# No Test or Debug Seam in Production Source

Scope: production Swift source under `**/Sources/**` that is NOT under `**/Tests/**`. This is the production-source sibling of `test-determinism.md` (which governs test files) and complements `swift-logging.md` (which governs diagnostic output).

A test-only or debug-only seam does not belong inline in production source. If a unit test needs to observe internal state, the test target reaches that state through `@testable import` after widening the declaration from `private` to `internal`. Production source should not grow accessors, hooks, or `#if DEBUG` extensions that exist solely to let tests or a debugger peek at otherwise-private state. The compiled-out `#if DEBUG` guard does not make this acceptable: it still adds a test-shaped surface to the shipping file, encodes the test's needs into production code, and invites more of the same.

The canonical case is https://github.com/manaflow-ai/cmux/pull/6452: a `#if DEBUG` `debugQueuedRequestCount()` accessor was added to the production `MobileCoreRPCSession`/`MobileCoreRPCClient` sources so a test could read the actor's private writer-queue state. The correct fix removed the production seam entirely, widened the queue state `private` -> `internal`, and observed it from `CmuxMobileRPCTests` via `@testable import CmuxMobileRPC`.

## Fail

Flag a file under a production source path (`**/Sources/**`, not `**/Tests/**`) when the PR adds any of these:

- A `#if DEBUG` (or `#if canImport(XCTest)` / `#if TESTING` / similar test-build guard) extension or member that exposes internal/private state for a test or debugger to read, with no production caller.
- A function or property whose name signals a test/debug seam: `debug…`, `…ForTesting`, `…ForTests`, `testOnly…`, `…TestHook`, `…TestSeam`, `_test…`, or an accessor that exists only to surface otherwise-private state.
- Widening visibility of production state to `public`/`internal` *and* adding a wrapper accessor in production source "so the test can call it" — when the test target could read the state directly via `@testable import` after a `private` -> `internal` widen.

## Pass

- The same observability achieved from the test target: state widened `private` -> `internal` (not `public` unless the public API genuinely needs it) and read through `@testable import`, with no test/debug accessor left in production source.
- A genuinely debug-only facility that is unavoidable in production code (e.g. a Debug-menu action, an in-app debug overlay, or a developer diagnostic command that a real user path invokes) isolated in a dedicated debug file or folder, not inlined into the main production type.
- Test scaffolding that lives in the test target (`**/Tests/**`), in a test helper module, or in a `Mocks`/`Testing` support target.
- Existing test/debug seams the PR merely touches incidentally without adding new ones.
- A `#if DEBUG` block that gates real product behavior (a developer-only feature, assertion, or logging), not a test-observability accessor.

## Report

When this rule fails, name the exact production source file and the test/debug member, state that a test-observability or debug seam was added to shipping source, and prescribe the smallest source-of-truth fix: move test scaffolding into the test target and reach internal state via `@testable import` (widening `private` -> `internal` as needed); if the facility is genuinely debug-only and unavoidable, isolate it in a dedicated debug file or folder. Cite https://github.com/manaflow-ai/cmux/pull/6452 as the reference fix.
