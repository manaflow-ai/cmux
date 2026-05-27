# Settings Organization And Search

Apply this rule to changes that add, move, rename, or remove settings UI, settings search entries, command-palette setting toggles, settings navigation targets, or persisted settings keys.

## Fail

- A new setting is placed in a broad or stale section when a narrower user-intent section already exists or should be created.
- A setting is moved or renamed without preserving old search muscle memory through aliases, keywords, or stable persisted key search terms.
- A settings search entry, command-palette setting toggle, JSON path anchor, or settings navigation target points to the wrong section after a settings organization change.
- A PR adds a visible setting but does not include enough synonyms for common names, old names, JSON keys, abbreviations, and adjacent product vocabulary.
- A settings category grows into unrelated behavior without a short rationale or a scoped split.

## Pass

- A setting stays in an existing category when the category still matches the user's intent and the PR improves search keywords for nearby terms.
- A setting move keeps persisted JSON keys unchanged and maps old section or setting aliases to the new section.
- A PR touches implementation details without changing the user-visible settings surface.

## Report

When this rule fails, name the exact file and line, identify the confusing category or missing search term, and suggest the smallest source-of-truth fix. Prefer fixes in `SettingsNavigation`, `SettingsSearchAliases`, and command-palette setting descriptors over one-off duplicate strings.
