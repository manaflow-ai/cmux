# User-Facing Error Messages

Flag production changes that add or materially change user-facing errors, alerts, command output, API error bodies, or recovery copy when they expose implementation details.

Fail when user-facing text includes:

- Upstream vendor or service names unless the user explicitly configured that vendor in the product UI.
- Internal provider names, provider-specific flags, templates, snapshots, manifests, environment variable names, database or migration details.
- Raw upstream error messages, stack traces, request ids from third-party systems, billing item ids, billing customer ids, or team ids unless the user supplied that exact id in the request.
- Secret material, credentials, tokens, headers, private keys, refresh tokens, session ids, or unredacted payload dumps.

Expected shape:

- State what happened in cmux/product terms.
- Give one or two concrete next actions the user can take.
- Put only safe, minimal diagnostics in `details`.
- Keep provider, billing, database, and auth implementation details in sanitized logs or internal telemetry, not in user-visible text.

Allowed cases:

- Developer-only comments, tests, docs, and operational runbooks that are not shown to end users.
- Existing public CLI flags or config keys in help text when the user asked for advanced configuration help.
- Generic terms such as "billing", "team", "Cloud VM service", or "Cloud VM state".
