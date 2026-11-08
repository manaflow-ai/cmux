# PR #10599 audit

Audit target: https://github.com/manaflow-ai/cmux/pull/10599
PR branch: `justincrich/cmux:upstream/file-preview-code-view-tokens-gutter`
Maintainer update remote: `https://github.com/justincrich/cmux.git`
Audited runtime head: `7cc7044a4f0a61172b416c883ade503bfe02b81a`
Merged base: `5a453950eac6e765e9d2eeb98fa45a68016f98b9`

## Merge and compatibility history

- `6cd9637127` merged `origin/main` with parents `c01ca68c09` and
  `93cb0a8a51`.
- `d671c5d257` merged the then-current `origin/main` with parents
  `d357804c02` and `544c0e0ff4`.
- `461f679445` merged the subsequently advanced `origin/main` with parents
  `d671c5d257` and `9e2dd50957`. The final PR head therefore has an explicit
  two-parent merge for the current base.
- `f4fd1ff5ab` merged the latest `origin/main` with parents `fe0f5540e6` and
  `5a453950ea`; its tree is the exact final PR tree.
- `d5a2941c78` is the small base-merge compatibility repair that uses
  `hostedView.surfaceView.terminalSurface` for portal teardown identity. It is
  unrelated to the File Preview redesign.
- `7cc7044a4f` is a Release-build compatibility repair. Swift 6.3's optimizer
  crashed while compiling the actor-isolated generic `Coordinator` deinit;
  the styler task now keeps only the highlighting actor across its await, so
  the styler's own deinitializer can cancel teardown safely without that
  compiler-crash path.
- The `Resources/Localizable.xcstrings` merge was resolved semantically. It is
  valid JSON, has no duplicate entries in its top-level `strings` object, and
  contains the union of both parent catalogs (5,577 keys).

## Findings closed

- Current-line and gutter drawing bounds glyph indices, handles empty and
  trailing-newline lines through `extraLineFragmentRect`, and avoids forcing
  unbounded layout from the draw path. Non-contiguous-layout fallbacks use only
  realized fragments.
- Syntax requests are actor-isolated and cancellation/generation guarded before
  policy, Highlightr/JSC setup, tokenization, and remapping. Stale queued edits
  are dropped; hidden tabs cancel and visible tabs force a fresh pass. No
  sleep-based debounce remains. The task capture also avoids retaining the
  styler across the highlighting await, allowing teardown cancellation.
- `FilePreviewLineIndex` lives in `Packages/macOS/CmuxFilePreviewCore` and uses
  packed separator-aware block treap storage with lazy suffix shifts. UTF-16
  edits, exact boundaries (including CRLF and edits ending at line starts),
  randomized/exhaustive behavior, and a valid 16 MiB dense fixture are covered
  without retaining a second document-sized source copy.
- Selection/caret changes invalidate the gutter and overlay; initial chrome
  setup refreshes the gutter index.
- The six new search keys and File Editor labels/subtitles have complete,
  non-placeholder values for all 20 supported app locales. Every routed web
  locale contains complete `schemaDescriptions.fileEditor` entries, including
  word-wrap title and alias coverage on both search surfaces.
- Production-only synchronization/accessor seams and test-only Highlightr
  injection were removed. Tests observe the real text-storage task signal with
  test-owned support and use stable RGB/hex color helpers.
- `FilePreviewEditorSettings` is constructable with injected `UserDefaults` and
  an instance-owned catalog. Runtime reads use that owner. Tab-width bounds and
  defaults are shared by the catalog, parser, UI, and editor; invalid JSON
  values are logged and ignored without dropping sibling settings.
- Pure line-index package/project/workspace wiring is present for `cmux` and
  `cmux-unit`; the old app-target source and duplicate test wiring are absent.
  `CmuxSyntaxHighlighting` is in the CI Swift package test list.
- The tracked root Xcode `Package.resolved` retains Highlightr 2.3.0, Sentry
  9.3.0, Sparkle 2.9.5, and all required existing pins. The tab-width Stepper
  has a localized accessibility label. Positive line-count policy and safe
  color packing are covered.

## Security result

The independent safety audit found no critical or high-exploitability issue.
Highlightr is pinned exactly; the change introduces no shell execution,
network/eval path, path traversal, authentication, or secret-handling path.
The size and line policy remains enforced before JavaScriptCore work.

## Review disposition

Fresh post-push feedback at the audited head reports 58 inline threads: all 58
are resolved, none are unresolved, and every thread has at least two comments
(145 thread comments total). The thread authors are Cubic (31), CodeRabbit
(25), and Greptile (2). Every previously silent resolved thread received an
evidence-backed maintainer reply; stale findings were explicitly identified as
outdated rather than silently dismissed. No review has state
`CHANGES_REQUESTED`; GitHub's aggregate decision remains `REVIEW_REQUIRED`
because external approval/CLA gates are not maintainer-controlled.

Top-level informational blockers remain external: Cursor Bugbot is paused at
its team spend limit, CodeRabbit is paused by its review policy, the
contributor's CLA is unsigned, and Vercel preview deployments require team
authorization. None produced a new actionable code finding at this head.

The saved policy result is clean. The recursive policy scan was not rerun, per
instruction.

## Verification

All focused Swift package commands used an arm64e invocation:

- `CmuxFilePreviewCore`: 11 tests in 1 suite passed, including the dense 16 MiB
  fixture and separator-transition randomized edits.
- `CmuxSyntaxHighlighting`: 24 tests in 5 suites passed.
- `CmuxSettings` focused catalog run: 8 tests passed.
- `CmuxSettingsUI` focused row-anchor run: 5 tests passed.
- `swiftc -parse` passed for touched app and test Swift files.
- `git diff --check` passed.
- `scripts/check-pbxproj.sh` passed.
- `python3 scripts/check-workspace-package-groups.py --check` passed.
- `python3 scripts/check-package-resolved-policy.py` passed (the checker emits
  benign merge-base notices for the two new local package manifests).
- `scripts/lint-pbxproj-test-wiring.sh` passed (735 test files checked).

The requested Swift length-budget script and
`.github/swift-file-length-budget.tsv` are absent in this checkout; that exact
absence was recorded. `.github/swift-warning-budget.tsv` was not modified.

## Tagged build and launch

The authorized command completed successfully for the code-affecting tree; the
final base merge changed only iOS sources and was rebuilt under the same tag:

```text
CMUX_SKIP_ZIG_BUILD=1 scripts/reload-cloud.sh --tag pr-10599-review --launch
```

Cloud runs: `pr-10599-review-8ac6289031ae` (code tree) and
`pr-10599-review-be7f3171c8ff` (final merged head).

The post-audit Release-compatibility repair was rebuilt and launched under the
same tag as `pr-10599-review-79f6047e9715`; its Debug build completed in 259s,
the installed identity and tagged socket were verified, and no launch failure
was reported. The next PR CI run must confirm the corresponding Release WMO
compiler path; the prior failure was a Swift frontend crash, not a source
diagnostic.

The installed and launched identity is `cmux DEV pr-10599-review` with bundle
identifier `com.cmuxterm.app.debug.pr.10599.review`. The matching tagged debug
socket responded to a workspace-list probe after launch. No launch failure was
reported. The consolidated audit-table comment is GitHub comment `5502995722`.

## Remaining external action

The PR remains open and is intentionally not merged. The contributor must sign
the CLA, and the Vercel team must authorize the `cmux41`/`cmux166` preview
deployments before those external gates can become green.
