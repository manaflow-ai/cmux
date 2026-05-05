# Swift Unified Logging

Flag production Swift logging that bypasses Apple's unified logging system.
Do not require new logs for new code paths. This rule only checks logging that
the diff adds or materially changes. Temporary debug probes belong in the
dogfood debug loop and should be removed before merge unless the PR explicitly
states that a sparse permanent diagnostic is intended.

Report a failure when the diff introduces or materially expands:

- `print`, `debugPrint`, `dump`, or `NSLog` in app/runtime Swift code.
- Ad hoc file logging or stdout/stderr logging for production diagnostics when `Logger` or the existing cmux debug log should be used.
- A file-scoped `Logger` that is not declared as `nonisolated private let` in code affected by MainActor-by-default isolation.
- Logging of secrets, tokens, passwords, private keys, customer content, or personal data without explicit private redaction.

Allowed cases:

- CLI command output that is the intended user-facing result.
- Tests and fixtures where stdout is part of the harness.
- Debug-only `NSLog` or cmux event logging guarded by `#if DEBUG`.
- Sanitized release diagnostics in `Sources/Providers/*` that intentionally use `NSLog` for provider observability, as long as the changed log cannot expose secrets or personal data.
- One-off local debugging that is removed before merge.

Preferred shape:

```swift
import os.log

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "FeatureName")
```

Use the right level: debug/info/notice for normal trace, warning for recoverable unexpected states, error/fault for broken behavior. Dynamic sensitive values should stay redacted or use `.private`.

When reporting, point to the changed logging statement and name the safer logging destination.
