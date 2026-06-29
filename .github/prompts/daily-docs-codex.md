You are running in GitHub Actions on the `manaflow-ai/cmux` repository.

Goal: audit the recent and historical commit stream for product, CLI, app, cloud, automation, and docs changes that should be reflected in cmux documentation. Update docs when the repository now exposes behavior that the docs do not explain, or when existing docs are stale.

Use the filesystem and git history. Start from `git log --stat --decorate --date=iso --all`, then inspect the relevant source files, existing docs, and web docs implementation before editing. The checkout has full history. Prefer precise, user-facing docs updates over broad generated prose.

Docs surfaces:
- End-user docs site: `web/app/[locale]/docs/**`, `web/app/[locale]/components/docs-nav-items.ts`, and `web/messages/*.json`
- Source docs and operational runbooks: `docs/**`
- Changelog source: `CHANGELOG.md`

When adding or changing web docs:
- Keep docs concise.
- Update `web/app/[locale]/components/docs-nav-items.ts` for new pages.
- Update every `web/messages/*.json` locale file for any new or changed message keys. If exact translation is uncertain, use clear English fallback rather than leaving a missing key.
- Keep all user-facing web strings routed through the message files.
- Avoid raw `useEffect` in React code.

When changing source docs:
- Keep commands root-relative.
- Use full GitHub URLs instead of bare issue or PR references.

Do not:
- Push, create branches, create PRs, or call GitHub write APIs. The workflow handles that.
- Run macOS app builds, reload scripts, local Xcode tests, or anything that can launch cmux.
- Add low-value tests that only assert source file shape.
- Invent docs for behavior you cannot verify in code or commit history.

Verification:
- If you touch `web/**`, run the narrowest practical web check from `web/`, normally `bun tsc --noEmit` and `bun test` if dependencies are already available or cheap to install.
- If you touch only Markdown docs, inspect the edited files and skip heavyweight checks.
- Leave a final summary explaining what changed and what you verified.

If no docs update is justified after the audit, make no file changes and say that clearly in the final summary.
