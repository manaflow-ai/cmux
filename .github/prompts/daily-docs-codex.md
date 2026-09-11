You are running in the daily cmux documentation audit workflow.

Goal:
Audit the cmux repository history and current implementation for documentation gaps. Update existing docs when behavior has changed, add new docs pages when a shipped feature deserves first-class docs, and keep docs navigation and localized strings in sync.

Required context to inspect:
- `git log --first-parent --name-status`, using `DOCS_AUDIT_COMMIT_WINDOW`. If `DOCS_AUDIT_COMMIT_WINDOW=all`, inspect the full first-parent history.
- `CHANGELOG.md`, `README*.md`, and `docs/`.
- The docs site under `web/app/[locale]/docs/`.
- Docs navigation in `web/app/[locale]/components/docs-nav-items.ts`.
- Locale files in `web/messages/*.json`.
- Current source code for features referenced by commits or docs.

Rules:
- Only make docs-related changes. Valid targets include `docs/`, `README*.md`, `CHANGELOG.md`, `web/app/[locale]/docs/`, docs-specific components, docs search tooling, and `web/messages/*.json`.
- Do not edit app/runtime code.
- Do not commit, push, create branches, create issues, or open pull requests. The workflow does that after your run.
- Prefer updating an existing page when the concept already exists. Add a new page only when it makes navigation clearer for a real user.
- Every user-facing docs-site string must use the existing `next-intl` message pattern. Add keys to every locale file. If a precise translation is not practical, keep the meaning simple and conservative.
- Keep copy short. Avoid marketing tone.
- Cite concrete commit SHAs or source files in your final summary when they drove a docs change.
- If no docs changes are needed, leave the working tree clean and explain why in the final summary.

Before editing, build a short plan from the commit audit. After editing, run the narrowest useful checks you can in the available time. The workflow will run web lint/build when web files changed.
