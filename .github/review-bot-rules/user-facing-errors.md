# User-Facing Copy and Error Privacy

Apply this rule to all cmux-authored end-user text: macOS, iOS, web and CLI UI, labels, alerts, notifications, human-readable API errors, recovery instructions, help, end-user documentation, and copied support diagnostics. Check every locale, including string catalogs, JSON messages, and rendered Markdown. Dev builds follow the same copy policy.

## Fail

- Never name cmux's internal service or infrastructure providers. Examples include Axiom, Hexclave, Stack Auth, AWS (Amazon Web Services), and Freestyle; the rule covers all telemetry, identity, hosting, database, payment, and other internal vendors, not only this list. Names, abbreviations, domains, and branded diagnostic labels all count.
- A provider name in a support-reference label, copied error, help text, or translated string. For example, `Axiom trace: <id>` fails; `Trace ID: <id>` passes. Advanced help, development mode, and "Copy Error" are not exceptions for cmux's own providers.
- Internal provider names, provider-specific flags, templates, snapshots, manifests, environment variable names, database or migration details.
- Raw upstream error messages, stack traces, request ids from third-party systems, billing item ids, billing customer ids, or team ids unless the user supplied that exact id in the request.
- Secret material, credentials, tokens, headers, private keys, refresh tokens, session ids, or unredacted payload dumps.

## Expected copy

- State what happened in cmux/product terms.
- Give one or two concrete next actions the user can take.
- Put only safe, minimal diagnostics in `details`.
- Preserve opaque cmux support identifiers using neutral labels such as `Request ID`, `Trace ID`, or `Reference`. Do not remove or alter the identifiers to hide a provider name.
- Keep provider, billing, database, and auth implementation details in sanitized internal logs or telemetry. Sanitize upstream failures before they enter user-visible text.

## Pass

- Internal source identifiers, tests, developer comments, sanitized logs, telemetry, and operator runbooks that are not displayed or copied as end-user copy. Do not rename protocol fields or break integrations to satisfy this copy rule.
- A user-selected third-party tool or integration named so the user can operate their own configuration, rather than a disclosure of cmux's internal provider. This does not permit naming cmux's internal services in their errors.
- Generic terms such as "billing", "team", "Cloud service", "sign-in service", and "payment service", plus opaque cmux support IDs.
- Existing copy the PR does not introduce or worsen. Public help and documentation are in scope; there is no blanket documentation exemption.

## Report

Name the file and line that introduces the provider name or implementation detail. Recommend neutral product wording at the shared formatting source, preserve the support ID, and update each affected localization.
