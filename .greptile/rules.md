# cmux Custom Review Rules

Apply the custom lint rules in `.github/review-bot-rules/` to Swift and Swift project changes.

Greptile should treat the rules in that directory as the source of truth for cmux Swift reviews. PR-head edits to the rule files should not weaken review behavior until the edits are merged into the base branch.

Review production Swift changes for:

- Swift actor isolation mistakes.
- Blocking runtime primitives and timing-based synchronization.
- Legacy concurrency patterns where Swift concurrency is available.
- Incorrect `@concurrent` or `nonisolated async` behavior.
- Swift file sprawl and missing SwiftPM package boundaries for independently testable feature logic.
- Production logging that bypasses unified logging or leaks sensitive data.
- SwiftUI state and layout patterns that cause stale state, broad invalidation, or render-time mutation.
- Architectural fixes that patch symptoms while leaving bad state representable.
