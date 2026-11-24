Leo, 2026-11-22 (ask-b9fd9d4f9c), verbatim:

> speaking of the make cmux yours type thing... ok. i think we can hill climb user-facing decisions. what are controversial things/divisive things, and what are cool things they can try, and what are ways we can bundle them, if we think about delineating and a/b testing across all manner of folk... what would people split on? what would people care to have opinions on from the get-go? we need a lot of fable dictators on this, actually. because this is hardening proposals and making sweeping decisions. [...]
>
> but mostly, yes. we want to be rigorous and just debate amongst ourselvse and incrementally go and keep hill climbing that, because that is somebody's front f\*\*\*ing door. what do they absolutely need to be able to decide with clicks, what do they need to have the best f\*\*\*ing front door possible, best intro possible, etc. and i guess they can maybe replay it to return to the walk of the settings.
>
> [...] the best possible batteries included possible, refining all things, making them all endlessly customizable.
>
> with a click. without rerendering. [...]

The debate he asked for has happened: five Fable dictators, each with its own lens (onboarding research, divisive choices and cuts, competitor batteries, Leo's profile, performance and reversibility), argued two rounds. The ruling is in cmuxterm-hq `docs/design/make-cmux-yours-intro-walk.md`. This PR lands its **indisputable** items 1 to 3, which round 1 said to land on green. The four-screen walk and the default flips are `[taste]` calls for Leo, so they are not here (filed with `tbd-leo`).

## What this carries

The stack's lane has been idle since 15:34Z. This PR rebuilds it as one branch on today's `feat-cmux-next`, which is 741 commits ahead of where the stack was cut. Its parts were:

- #49701: Make cmux Yours offers all five densities (by Settings' names), a curated set of calm backgrounds, and the Opacity and Material rows. Skip and Escape put back what was set when the window opened. Continue keeps the picks.
- #50500 (doc item 1): a pick, its linked edits included, is **one publish** of the settings file. Skip restores the file's values from when the window opened, also in one publish, so a replay over a person's own settings loses nothing.
- #50394 (doc item 3): one selection language. Segmented tracks have a sliding plate (transform only; off under Reduce Motion), tiles are quiet, and Recommended is a tag. The Opacity and Material rows stay in place, dimmed, when Background is None, so nothing jumps.
- #50532 (doc item 2, "replay it to return to the walk"): the palette command **Make cmux Yours** (`home.makeItYours`, with its Rust row in `cmux-action-catalog/src/catalog/home.rs` and 21 locales) reopens the step on the current settings. The first-run flag is untouched.

#49701 is Austin's; it has been idle since 03:16Z with review fixes done, so it is carried forward here (idle pass), not rewritten.

The only conflict was in `BoundActionCatalogTests.awaitingRepin`, where base had already removed `debug.tooltipGallery` and `home.meetChief` after their re-pin. Only `home.makeItYours` is kept there.

Nothing is removed and no default changes. #50537 (gallery arms for the four-screen walk) stays a separate PR, because it is the variants Leo decides on.

## Checks run on this head

- `cmux-ci compile-check --app` at `6d0c89291fea`: passed (job `ed5442b8de76c46f08044375`, 155 s).
- `scripts/ci/crash-class-gate.sh` against `feat-cmux-next`: `check-concurrency: ok` (it was red on #50500 and #50532 at their old bases).
- `risk_tier.py classify`: normal.
- `bun test src/pages/onboarding`: 52 pass, 1 fail. The fail (`cmux tools > asks before giving anything`, in `Onboarding.test.tsx`) fails the same way on base `feat-cmux-next`.
- Typecheck and `cargo test -p cmux-action-catalog` are running; results go in a comment.
- Helper review: SHIP. Its two Skip findings are fixed in `50b6dd62aa5`: a palette reopen right after Skip no longer loses that Skip (test `reopenRightAfterSkipKeepsTheSkip`), and a failed open-time read falls back to writing the old choices. The rest (a refused write is not shown on the page, Skip overwriting a Settings edit made while the window is open) are follow-ups, not regressions.

## Capture

This is a webview, so the before and after are gallery `pages.onboarding` captures (the variants are in #50394 and #50537). The real capture follows on the fleet from this head.

`parity-mac.md` keeps the Make cmux Yours row as #48514 wrote it; the step's new picks and its palette replay get their own row below it.

Supersedes #49701, #50500, #50394 and #50532 when it merges.

## Adopted 2026-11-23 (ask-b9fd9d4f9c lane), head `53a2a0f2106`

- Merged `feat-cmux-next` at `c50cc7c1b54` (clean; no settings schema touched, so nothing to regenerate).
- Base's new `action_contract.rs` requires a `cli_name` on every row; `home.makeItYours` had none. It is GUI-only like `home.meetChief`, so it takes `action home-make-it-yours`. `cargo test -p cmux-action-catalog`: all pass (it failed `every_action_has_a_unique_noun_verb_cli_name` before).
- `bun test` on each `src/pages/onboarding` file: 53 pass, 0 fail. `tsc --noEmit`: nothing in onboarding.
- The earlier reds were not this PR: clippy hit `acpmux` E0004 on `CircuitService::TransferSource` at old base `79617f0da0e` (covered at the tip, `hub_carrier_mux.rs:357`). The fast tier was refused for a busy seed root, generated-files stopped mid-compile with no error, the GhosttyKit download timed out, and the web jobs were cancelled.
- Helper review at this head: no blockers; all four claims hold. One should-fix goes to a follow-up: a palette reopen while the last window's restore is still queued shows the old picks on the page (the file is right).

Duress: not a perf change. The step writes one publish per pick, as before this adoption.

Leo-ask: ask-b9fd9d4f9c
Leo-Ask-Trace: ask-b9fd9d4f9c

## Changelog

- Make cmux Yours (first run) offers every density, calm backgrounds with Opacity and Material, and Skip puts back exactly what you had.
- New palette command: Make cmux Yours, to walk through it again at any time.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

## Carry-forward status

This PR carries #50975 on the current `feat-cmux-next` base because the original branch is owned by another live lane. It uses the distinct branch `lane/onboarding-front-door-carry-v2` because `lane/onboarding-front-door-carry` is already held by carry PR #54513. The synchronized head is `5f00420b4cc890a392b92740806b38cbd3f0b6f6`.

The merge preserves the onboarding implementation and resolves the current base conflict in `MakeItYoursStepModel.swift` in favor of the PR's write-through and Skip-baseline behavior.

## UI evidence

Screenshots are being added from the `pages.onboarding` gallery Make cmux Yours variants. Waiting on Leo: UI

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Agent session: [agent session](https://cmux.com/deeplink/agent?id=aid-b74639bb2d21c59a6a8b&model=claude-opus-5-5)
