# cmux Custom Review Rules

Apply the custom lint rules in `.github/llm-diff-lint/rules/` to Swift and Swift project changes.

These Greptile rules are additional review coverage. The required `LLM Diff Lint` GitHub Action remains the authoritative CI gate because it runs trusted base-branch rules under `pull_request_target`.

Review production Swift changes for:

- Swift actor isolation mistakes.
- Blocking runtime primitives and timing-based synchronization.
- Legacy concurrency patterns where Swift concurrency is available.
- Incorrect `@concurrent` or `nonisolated async` behavior.
- Production logging that bypasses unified logging or leaks sensitive data.
- SwiftUI state and layout patterns that cause stale state, broad invalidation, or render-time mutation.
- Architectural fixes that patch symptoms while leaving bad state representable.
