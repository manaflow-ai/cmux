# cmux Custom Review Rules

Apply the custom lint rules in `.github/review-bot-rules/` to Swift, runtime, and project changes.

Greptile should treat the rules in that directory as the source of truth for cmux reviews. PR-head edits to the rule files should not weaken review behavior until the edits are merged into the base branch.

Review production Swift and runtime changes for:

- Swift actor isolation mistakes.
- Blocking runtime primitives and timing-based synchronization.
- Fixed sleeps, delays, and polling used as hacky synchronization.
- Legacy concurrency patterns where Swift concurrency is available.
- Incorrect `@concurrent` or `nonisolated async` behavior.
- Swift file sprawl and missing SwiftPM package boundaries for independently testable feature logic.
- Production logging that bypasses unified logging or leaks sensitive data.
- User-facing text that is not fully internationalized across every supported app or web locale.
- SwiftUI state and layout patterns that cause stale state, broad invalidation, or render-time mutation.
- Architectural fixes that patch symptoms while leaving bad state representable.
- User-facing errors, alerts, command output, API error bodies, and recovery copy that expose implementation details.

## Full Internationalization

For production user-facing text, require complete internationalization across every locale supported by the affected surface.

Flag Swift UI, menu, alert, tooltip, error, recovery, or command text that is not routed through `String(localized:defaultValue:)` or an equivalent localized API with a matching translated string-catalog entry. Flag app string catalog or Info.plist additions and edits that do not include translated entries for every locale already supported by the touched catalog. Flag web UI text, API response copy, user-facing web data, metadata, route copy, rendered markdown, changelog copy, or message keys that are not consumed from `next-intl` or another locale-specific source and represented across all locales in `web/i18n/routing.ts` and every matching file in `web/messages/`.

Pass for tests, operational docs not shown to end users, developer-only comments, debug-only logs, exact protocol/config tokens, and existing untranslated strings the PR does not introduce or worsen.

## User-Facing Error Messages

For production user-facing errors, alerts, command output, API error bodies, and recovery copy, do not expose implementation details.

Flag copy that includes upstream vendor or service names, internal provider names, provider-specific flags, templates, snapshots, manifests, environment variable names, database or migration details, raw upstream error messages, stack traces, request ids from third-party systems unless the user supplied that exact id, billing item ids, billing customer ids, team ids not supplied by the user, credentials, tokens, headers, private keys, refresh tokens, session ids, or unredacted payload dumps.

Error copy should say what happened in cmux terms, provide concrete user actionables, and keep only safe minimal diagnostics in `details`. Provider, billing, database, and auth implementation details belong in sanitized logs or internal telemetry.
