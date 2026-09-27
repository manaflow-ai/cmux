# Landing Page Registry Parity

Apply this rule when a PR adds a new marketing landing/guide page under `web/app/[locale]/(landing)/<slug>/page.tsx`. Each such page is referenced by several separate registries, and adding the route without updating all of them ships a page that is unlinked, unindexed, or breaks a test.

A new `(landing)` page must be registered in every one of these in the same PR:

- `web/app/sitemap.ts`: a localized entry for the new path, so the page is in the sitemap.
- `web/app/lib/agent-page-paths.ts`: an `agentReadablePages` entry for the new path. This is what gives the page its `.md`/`.txt` agent-readable variant and its `llms.txt` listing. `tests/agent-page-variants.test.ts` iterates `sitemap()` and asserts every sitemap path resolves to a variant, so a sitemap page missing from `agentReadablePages` fails CI.
- `web/app/[locale]/(landing)/guides/page.tsx`: an `ARTICLES` entry, so the page is discoverable from the `/guides` index.
- `landing.links` in `web/messages/en.json` (and a matching cross-link from related pages' `related` lists), so the new page is internally linked.

Localization of the new page's copy into every locale is covered by `full-internationalization.md`; do not duplicate that check here, but do confirm the new `landing.*` namespace and `landing.links` entry exist in every locale.

Report a failure when a diff:

- Adds a `web/app/[locale]/(landing)/<slug>/page.tsx` (or otherwise adds a path to `web/app/sitemap.ts`) without a corresponding `agentReadablePages` entry in `web/app/lib/agent-page-paths.ts`.
- Adds a landing page to `sitemap.ts` but not to the `/guides` `ARTICLES` list, leaving it absent from the guides index.
- Adds a landing page without a `landing.links` label and at least one internal cross-link to it from a sibling page.
- Adds an `agentReadablePages` entry whose path is not in `sitemap.ts`, or vice versa, so the two drift.

Allowed cases:

- Pages intentionally excluded from the sitemap or `/guides` (for example legal pages, deeplink handlers, or redirect-only routes) when the PR keeps them out of `sitemap.ts` consistently and does not add them to `agentReadablePages` either.
- Non-landing routes outside `web/app/[locale]/(landing)/`.
- Edits to an existing landing page that do not add a new route.
- Existing registry drift the PR does not introduce or worsen, though mention nearby drift when it is adjacent to the change.

When reporting, name the new slug and the exact registry file it is missing from (`sitemap.ts`, `agent-page-paths.ts`, `guides/page.tsx`, or `landing.links`), state which registry is out of sync, and suggest adding the one missing entry.
