# PR #10599 audit

Audit target: [manaflow-ai/cmux#10599](https://github.com/manaflow-ai/cmux/pull/10599)  
PR branch: `justincrich/cmux:upstream/file-preview-code-view-tokens-gutter`  
Maintainer update remote: `https://github.com/justincrich/cmux.git`  
Audited head: the final pushed PR head (the exact SHA is reported with the
handoff and on the PR; this report's last code-affecting head is noted below)

The branch includes merge commit `7efb561256` with the required parents
`d1f2e982cb` and `857b5af7a8396d5239679fbb8341fbd3ca8c541e`. The merge conflict
in `Resources/Localizable.xcstrings` was resolved semantically: the catalog
parses as JSON, has no duplicate top-level keys, and retains both the PR and
`main` entries. A small base-merge compatibility repair changed the portal
teardown lookup to `hostedView.surfaceView.terminalSurface`; it is unrelated to
the File Preview design and was required for the merged base to compile.

## Findings closed

- Current-line and gutter drawing bounds glyph indices, handles empty and
  trailing-newline lines through `extraLineFragmentRect`, and avoids forced
  unbounded layout in the draw path. Non-contiguous-layout fallbacks use only
  realized fragments.
- Syntax requests are actor-isolated, cancellation/generation guarded before
  policy, Highlightr/JSC setup, tokenization, and remapping. Stale queued edits
  are dropped; hidden tabs cancel and visible tabs force a fresh pass. No
  sleep-based debounce remains.
- `FilePreviewLineIndex` lives in `Packages/macOS/CmuxFilePreviewCore` and uses
  block implicit-treap storage with lazy suffix shifts. UTF-16 edits, exact
  line-start boundaries, randomized/exhaustive behavior, and a tagged dense
  16 MiB fixture are covered.
- Selection/caret changes invalidate the gutter and overlay; initial chrome
  setup refreshes the gutter index.
- The six new search keys have complete non-placeholder values for every
  supported app locale. `schemaDescriptions.fileEditor` is present in every
  routed web locale, and word-wrap title/alias coverage is checked on both
  search surfaces.
- Production-only synchronization/accessor seams and test-only Highlightr
  injection were removed. Tests await the internal real task signal and own
  their color helpers.
- `FilePreviewEditorSettings` remains constructable with injected
  `UserDefaults`; runtime reads use the instance-owned catalog. Tab-width range
  and defaults are shared by the catalog, parser, UI, and editor; invalid JSON
  values are logged and ignored without dropping sibling settings.
- Pure line-index package/project/workspace wiring is present for `cmux` and
  `cmux-unit`; the old app-target source and duplicate test wiring are absent.
  `CmuxSyntaxHighlighting` is in the CI Swift package test list.
- The tracked Xcode package lockfile was verified with the pinned Highlightr
  2.3.0 dependency and all existing pins intact. The tab-width stepper has a
  localized accessibility label. Positive line-count policy, safe color
  packing, stable RGB test comparison, and catalog metadata regression tests
  are covered.

## Security result

The independent safety audit found no critical or high-exploitability issue.
Highlightr is pinned exactly; the change introduces no shell execution,
network/eval path, path traversal, authentication, or secret-handling path.
The size/line policy remains enforced before JavaScriptCore work.

## Review disposition

Live feedback was fetched repeatedly with the HQ PR-feedback helper. Cubic's
23 review threads are resolved. Outdated findings (representable reuse,
line-fragment fallback, policy transition, parser-test coverage, and prior
access visibility) received evidence-backed replies and were resolved; current
catalog/test findings were fixed and resolved as well. Cursor Bugbot is paused
because its team spend limit is reached; CodeRabbit is paused by its review
policy; neither produced an actionable code finding.

The canonical HQ autoreview reached a clean merge-conflict gate but exited
without structured findings because the reviewer service returned HTTP 503
(`refresh_token_reused`/reauth required) on two identical retries. This is an
external review-engine infrastructure blocker, not a code disposition.

## Verification

All package commands used an arm64e invocation:

- `swift test --package-path Packages/macOS/CmuxFilePreviewCore` — 8 tests pass,
  including the dense 16 MiB case.
- `swift test --package-path Packages/Shared/CmuxSyntaxHighlighting` — 24 tests
  in 5 suites pass.
- `swift test --package-path Packages/macOS/CmuxSettings` — 300 tests in 50
  suites pass.
- `swift test --package-path Packages/macOS/CmuxSettingsUI` — 151 tests in 28
  suites pass.
- `git diff --check` — pass.
- `scripts/check-pbxproj.sh` — pass.
- `python3 scripts/check-workspace-package-groups.py --check` — pass.
- `python3 scripts/check-package-resolved-policy.py` — pass (only benign
  merge-base notices for the new local package manifests).
- `scripts/lint-pbxproj-test-wiring.sh` — pass (731 test files checked).

The requested Swift length-budget script and
`.github/swift-file-length-budget.tsv` are absent in this checkout; that exact
absence was recorded and no warning-budget file was modified.

## Tagged build and launch

The authorized command was run from the clone root:

```text
CMUX_SKIP_ZIG_BUILD=1 scripts/reload-cloud.sh --tag pr-10599-review --launch
```

(`reload-cloud.sh` is invoked from the maintainer HQ checkout.)

Final runtime build run `33469654129` completed successfully for head
`1dcb7a2ef4`; subsequent heads `9ec5890b06`, `be4c45ad76`,
`4aa4d6848d`, and `277b400c85` contain only tests/documentation. The earlier
post-merge failure `33468023359` was the single `GhosttySurfaceScrollView`
compatibility error documented above; the repaired rebuild passed. The app
identity is `cmux DEV pr-10599-review` with bundle identifier
`com.cmuxterm.app.debug.pr.10599.review`. The tagged socket was verified live,
and the tagged app was relaunched after verification. The local tag opener is
emitted by the reload command and is not included in this tracked report.

## Remaining external action

The PR remains open and was not merged. GitHub still reports the contributor
CLA Assistant failure (the contributor must sign the CLA) and Vercel preview
authorization is required for the `cmux41`/`cmux166` deployments. Those gates
cannot be completed by this code-only maintainer session.
