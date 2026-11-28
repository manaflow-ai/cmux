# Full Internationalization

Flag production changes that add or materially change user-facing text without fully internationalizing it across every locale supported by the affected surface.

Report a failure when the diff introduces or materially changes:

- Swift UI, menu, alert, tooltip, error, recovery, or command text that is not routed through `String(localized:defaultValue:)` or an equivalent localized API.
- A new Swift localization key that is not backed by a matching `Resources/*.xcstrings` entry with English and Japanese values.
- A new or changed `Resources/*.xcstrings` key that does not include English and Japanese entries.
- A new app locale, language file, or string catalog entry that is only wired for English or a subset of existing app locales.
- Web UI text, API response copy, user-facing web data, metadata, route copy, rendered markdown, changelog copy, or message keys that are not consumed from `next-intl` or another locale-specific source and represented in `web/messages/en.json` and `web/messages/ja.json`.
- Placeholder, copied English, machine marker, TODO, or empty translations used to satisfy a locale slot.

Expected shape:

- New user-facing Swift text uses a stable localization key, an English `defaultValue`, and a matching string-catalog entry.
- `Resources/Localizable.xcstrings` and `Resources/InfoPlist.xcstrings` additions include English and Japanese. The `localization-fill` workflow fills the other locales on main and lands them as its own PR; until then they fall back to English. Do not flag a PR for leaving them out.
- Web message, API response, rendered markdown, changelog, and user-facing data changes read from locale-specific entries at runtime, update the English and Japanese entries, and keep the locale registry aligned with available messages.
- If a locale is intentionally removed or added, the PR updates the canonical locale list and every affected message/catalog file in the same change.

Allowed cases:

- Developer-only comments, tests, fixtures, debug-only logs, and operational docs not shown to end users.
- Protocol identifiers, file names, command names, config keys, environment variable names, bundle identifiers, and other literal tokens that must stay exact.
- Existing untranslated strings that the PR does not introduce or materially worsen, though mention nearby debt if it could cause a regression.
- Temporary product copy in prototypes only when the PR explicitly excludes the code path from production builds.

When reporting, identify the new or changed user-facing text, the missing localization API or runtime locale source, the missing locale entries, and the exact catalog or message files that need updates.
