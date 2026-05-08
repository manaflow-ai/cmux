# Swift Concurrent Annotation

Flag incorrect or missing use of Swift's `@concurrent` and `nonisolated async` behavior.

Report a failure when the diff introduces or materially expands:

- `nonisolated async` work that is expected to leave the caller's actor but is not annotated `@concurrent` under the Swift 6 `NonisolatedNonsendingByDefault` behavior.
- `@concurrent` on a synchronous function.
- `@concurrent` combined with actor isolation such as `@MainActor`.
- `@concurrent` functions that access actor-isolated or main-actor state directly.
- CPU-heavy, file I/O-heavy, parsing-heavy, or network-heavy async helpers called from UI isolation without an explicit actor hop or `@concurrent` boundary.

Allowed cases:

- `nonisolated` synchronous pure helpers.
- Async functions that intentionally inherit the caller's actor and only coordinate UI-bound work.
- Existing functions where the PR does not change isolation, execution cost, or call sites.
- Actor methods that must access isolated state and therefore cannot be `@concurrent`.

Use this rule only for correctness or responsiveness. Do not report style-only annotation preferences.

When reporting, identify the changed async function or call site and state whether the fix is to add `@concurrent`, remove `@concurrent`, move work into an actor, or keep execution on `@MainActor`.
