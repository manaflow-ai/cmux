# cmux agent notes

## Setup

`./scripts/setup.sh` initializes submodules, builds GhosttyKit, and installs the pbxproj normalization pre-commit hook.

Before committing, setup or a native build, [choose verification for the changed area](skills/cmux-testing/references/local-vs-ci-validation.md). `python3 scripts/verify-local.py` runs fast static checks; docs and portable-tooling changes do not automatically require an app build. Run it only on code you trust: the checker executes repository scripts, including those in a `--repo` target. There is no automatic candidate-code execution on push; see the [trust boundary](docs/contributor-verification.md#trust-boundary).

## Tagged builds

Always build with a tag. **Never run bare `xcodebuild` or open an untagged
`cmux DEV.app`**: untagged builds share the default debug socket and bundle ID
with other agents. Never report a raw `.app` path or a `file://` URL.

Build with `./scripts/reload.sh --tag <branch-slug>` (add `--launch` to open it).
In a checkout not created through cmuxterm-hq, set `CMUX_DEV_BACKEND_MODE=local`. Reuse
the tag's DerivedData and prebuilt GhosttyKit before a cold build, and clean up
only tags you own; the compile-only command, reload variants and GhosttyKit
rebuild are in [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md).
Team members: the shared build fleet and its rules are in cmuxterm-hq.

### Intel Macs, Xcode 16.2, Swift 6.0

The macOS app also builds on Intel Macs running macOS 14 with Xcode 16.2 (Swift 6.0.3), including tagged `./scripts/reload.sh` dev builds; `GhosttyKit.xcframework` already ships fat x86_64+arm64 slices targeting macOS 13. Xcode 26 stays the pinned toolchain (`.xcode-version`) for CI, releases, and the iOS app; this pathway is best effort and changes nothing for Xcode 26. Code linked into the macOS app (`Sources/`, `CLI/`, `TunnelExtension/`, and the packages it depends on) stays within Swift 6.0 syntax: no trailing commas in parameter or argument lists (SE-0439, Swift 6.1), no `nonisolated` on struct/enum/class/protocol declarations (SE-0449, Swift 6.1; member-level `nonisolated` is fine), and the existing `#if compiler(>=6.2)` / `#else @Sendable` split for `@concurrent` (SE-0461 is Swift 6.2; the Swift 6.0 compiler does not implement it and only warns that the attribute was renamed, so it must not be relied on for the 6.2 semantics). macOS 26-only APIs stay behind their `@available`/`#available` checks and are simply unavailable at runtime on macOS 14. `cmuxTests/`, `cmuxUITests/`, and `Packages/iOS/` are outside this pathway.

## Tag-bound debug CLI

For CLI or socket dogfood against a tagged Debug app, use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh <command>` ([details](skills/cmux-dev-workflow/references/tagged-builds.md#tagged-cli-and-socket)). Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

## Area-specific instructions

Rules that only matter in one part of the tree live next to that code. Read the file before working there; not every agent loads a nested file on its own when launched from the repository root.

- `ios/`, `Packages/iOS/`: `ios/AGENTS.md` (Apple HIG rule, iPhone install and auth gates, local simulators, cross-tag Mac access, dev auth profiles).
- `web/` and any cmux Cloud database work: `web/AGENTS.md` (database provider).
- `cmux-tui/`: `cmux-tui/AGENTS.md` (hosted verification, Blacksmith Testbox).

## Public writing

Before drafting or revising a top-level issue or PR description, read [STYLE.md](STYLE.md). It also covers RFCs and progress updates.

## Changelog

When a user-visible change merges, add one line under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md) (PR link, `-- thanks @user!` for outside authors).

## Outside contributors

Before fixing a bug or building a feature, run `gh search prs --repo manaflow-ai/cmux --state open '<symptom or issue number>'` and look for an outside PR (author not on the team). If one exists:

- Prefer landing theirs. Push fixups to their branch when "Allow edits by maintainers" is on, and say what you changed.
- If you write your own fix instead, add `Co-authored-by: Name <email>` for them to every commit that uses their approach, using the email from their commits (`git log --format='%an <%ae>'` on their branch). Then comment on their PR with a link to yours and a plain thank-you, and let a human close it.
- Never close an outside PR without a human-written comment saying why.

## Choosing CI coverage

`full-ci` requests the expensive full macOS suite policy. It is not shorthand
for normal PR checks, relevant tests, review readiness, or permission to merge.
Do not add it as a generic review or merge requirement. First identify the
lanes needed by the change and use existing routed checks or targeted validation.
Add `full-ci` only when the user or agreed validation plan explicitly calls for
the broad suite; state which additional lanes are needed and why.

Normal PR CI can already run routed tests, including Swift package and CLI
wrapper checks, without `full-ci`. A `cmuxTests/` diff runs the suites it
declares or extends, and an app-source diff runs the suites whose tests mention
what it changed (`reverse_test_impact.py`, #14418), in one changed-suites batch
with no label (edited suites over its budget take all seven shards). `unit-ci` runs
every app-host suite across all seven workers; `full-ci` adds the other lanes on
top. Neither is needed to test the suites you edited. A change to how the suites
are laid out over the workers (the timings file, the sharder, the batch runner, or
the job's matrix and shard env) runs every app-host suite on its own. No PR job runs
`cmuxUITests/`; `no-full-ci` records a deliberate skip for `suite-coverage`. The label permits eligible app-host shards,
lag builds, and other full-suite lanes; path routing, release routing, and job
dependencies still apply. It does not request every repository test. Inspect
actual executed tests on the current SHA: a green skipped job is not coverage.
Adding or removing the label affects new event runs, not the label snapshot of
an existing run or a rerun of that event.

## Regression test commits

Keep two commits: first the failing behavioral regression, then the fix. Run the
same focused command on both and record the commit SHAs, expected failure, and
passing result. A setup failure or zero executed tests is not regression proof.
When this proof is available locally, push both commits together after the fix
passes; a separate hosted CI run on the deliberately broken intermediate commit
is unnecessary. If the failure only reproduces in CI, use that lane and retain
its receipts. Required CI and review still apply to the final pushed head.

## Merging main into a branch

Don't bring main into your branch yourself. When main's fast guards go green, `pr-catch-up.yml` merges that commit into open pull requests that conflict with main or are red only because of main, once their head has been quiet for 30 minutes (label `no-auto-catch-up` to opt out). It resolves generated-file conflicts, pushes, and CI runs on the result. A conflict it can't resolve gets one comment on the PR; that is your cue to merge by hand. To catch up sooner, comment `/catch-up` on the PR.

If a push is rejected because the branch moved, run `git pull --no-rebase` and push again; never force-push over the catch-up merge.

When you do need main locally (you depend on something that just landed, or catch-up asked you to resolve a conflict), use `scripts/merge-main.sh`, not a raw `git merge origin/main`. It merges the newest main commit whose CI fast guards passed, resolves generated-file conflicts the same way, then runs `scripts/ci/guards-local.sh` and labels each failure inherited from main or introduced by this branch. Fix the introduced ones; the inherited ones are main's. `--dry-run` shows the pick, `--tip` merges a red tip on purpose. See [docs/ci/merge-main.md](docs/ci/merge-main.md).

## First pass, then dogfood

A first pass ends when the change is implemented, [scoped verification](skills/cmux-testing/references/local-vs-ci-validation.md) passed, and the PR is open. Native app/build-input changes require the tagged build on the pushed HEAD and focused tests; `web/` PRs also require the live Vercel preview URL. Docs and portable contributor tooling use their relevant checks without an unrelated app build. Then hand off; do not sit watching CI or running speculative review passes.

**Review with a subagent before merge.** Spawn a review subagent on the exact diff, correctness first ([cmux-review](skills/cmux-review/SKILL.md)), fix what it finds, and run a quick second subagent pass when the fixes were non-trivial. Do not use a second model (`codex review`, `$autoreview`) as a review gate. Let required GitHub checks and review bots run asynchronously, then address only concrete check failures and actionable findings before merge.

**Merge fast, not blind.** `main` is our nightly: stack fixes, do not revert. Before merging, wait for the checks that judge the change (macOS compile admission plus the app-host suites CI selected for it) and skip slow unrelated lanes. If you merge without them, say on the PR what was not verified; the merge receipt (`merge_receipt.py`) records it and labels the PR `merged-unverified`. A main-regression comment on your PR (`main_regression_attribution.py`) is a fix-forward ask.

The main agent owns dogfood, approval, mergeability, and every pushed fix. Merging app/runtime/UI changes requires the user's explicit approval after dogfood or a direct merge directive that names the merge action (`merge`, `merge it`, `auto-merge`; `finish`, `lgtm`, and `ship it` are not); if a fix changes runtime behavior mid-dogfood, rebuild the tag and re-notify, since the earlier verdict covers only the build the user tested. After a merge directive, re-dogfood (rebuild the tag and re-notify with the checklist) when a later fix changes user-visible behavior beyond what was dogfooded; skip it for internal, test-only, or tightly scoped fixes; either way, say on the PR which you did and why.

Notify with `cmux notify` when a cmux socket is available.

## Pitfalls

Each of these has full detail in the skill named in parentheses.

- **Typing-latency-sensitive paths** (`cmux-debugging`): `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`, `TabItemView` in `ContentView.swift`, and `TerminalSurface.forceRefresh()` in `Packages/macOS/CmuxTerminal` run on every keystroke. Read the skill before touching them.
- **SwiftUI list boundaries** (`cmux-debugging`): no view below a `LazyVStack`/`LazyHStack`/`List`/`ForEach` boundary may hold an observable store reference, and no function called from `body` may write state. Violating either reintroduces the 100% CPU spin loop from https://github.com/manaflow-ai/cmux/issues/2586. Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **Do not add an app-level display link or manual `ghostty_surface_draw` loop.** Rely on Ghostty wakeups and its renderer, or typing lags.
- **Terminal find layering** (`cmux-debugging`): `SurfaceSearchOverlay` mounts from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), never from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- **Submodule safety** (`cmux-ghostty`): push the submodule commit to its remote `main` before committing the pointer in the parent repo. Never commit on a detached HEAD. Verify with `git merge-base --is-ancestor HEAD origin/main`.
- **Localize every user-facing string** (`cmux-localization`): `String(localized:)` with keys in `Resources/Localizable.xcstrings`, plus every web locale declared by `web/i18n/routing.ts` with a matching `web/messages/<locale>.json` entry. New macOS strings need the nine locales `scripts/localization_catalog.py` requires: English, German, French, Arabic, Spanish, Traditional Chinese, Simplified Chinese, Korean, and Japanese (`en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`); the catalog also carries partial translations for other languages. A localization audit is required for any UI, Settings, menu, schema, docs, or help-text change, and the handoff must state what was audited.
- **Shortcut policy** (`cmux-keyboard-shortcuts`): every new cmux-owned shortcut goes in `KeyboardShortcutSettings`, is editable in Settings, is supported in `~/.config/cmux/cmux.json`, and is documented.
- **Test wiring** (`cmux-testing`): a `.swift` file in `cmuxTests/` without a `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently skipped, and both `xcodebuild test` and bot reviews pass with "Executed 0 tests". Run `./scripts/sync-test-wiring` after adding, renaming, or deleting a direct test file; `--check` is read-only. `workflow-guard-tests` keeps `./scripts/lint-pbxproj-test-wiring.sh` as the defensive guard.
- **SPM package groups** (`cmux-architecture`): packages live under `Packages/{Shared,iOS,macOS}/<pkg>` and the workspace mirrors that folder shape. To move one, `git mv` the directory then `python3 scripts/check-workspace-package-groups.py --write`. Never hand-edit workspace group membership.
- **Do not gitignore cmux-owned `Package.resolved`.** SwiftPM resolution changes must show in PR diffs; package-local lockfiles are not replaced by the root one. `python3 scripts/check-package-resolved-policy.py` fails on drift.
- **"Feature flag" means a remote PostHog runtime flag.** Implement through `CmuxFeatureFlags` with a PostHog key, explicit unavailable fallback, registry metadata, live update behavior, and focused tests. A local override may support dogfood but must not be the production control plane.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change between macOS major versions.** `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 (https://github.com/manaflow-ai/cmux/issues/4529); CI and maintainer machines were all on the fixed side while every reporter was on the broken side. Test on the reporter's macOS before declaring a repro disproven. CI's `blacksmith-6vcpu-macos-15` pool runs macOS 15.

## Shared behavior policy

When a behavior is exposed through multiple entrypoints (shortcut, command palette, context menu, CLI, settings, debug menu), implement one shared action path and verify every entrypoint. Do not patch one surface and leave the others with duplicated logic.

For optimistic UI or CLI updates, keep one mutation path, record pending state with a request id or previous snapshot, reconcile from the authoritative result, and roll back explicitly on failure. Do not let each entrypoint keep its own optimistic copy.

When a user says tests missed a bug, add behavior-level coverage around the exact repro path before claiming the fix is complete.

## Remote CLI relay authorization (GHSA-9vmv-3hjw-j28c)

Every v2 socket method you add or touch is a potential `cmux ssh` relay payload. The relay on the remote host authenticates but does not trust: `RemoteRelayCommandPolicy` (`Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/`) denies every method by default and only forwards an allowlist, scoped to objects the remote session owns, with command-bearing params (`initial_command`, `command`, `tmux_start_command`, `pane_start_command`) denied on all methods.

Rules when adding a v2 method or a remote CLI command (`daemon/remote/cmd/cmuxd-remote/commands.go`):

- **Default is deny, and deny is safe.** A new method that is not added to the policy allowlist simply does not work through `cmux ssh`. Only add it when the remote product flow needs it.
- **Before allowlisting a method, answer in the PR description:** can it execute commands or open content on local objects (spawn terminals, respawn, send keys/text, eval scripts, open URLs)? Can it mutate or destroy objects the remote session does not own (close/rename/delete by ID)? Does it read local state the remote has no business seeing? If any answer is yes, do not allowlist it; reshape the method or its params instead.
- **Never allowlist a method that spawns or respawns terminals**, unless you have verified in the running app that the target executes on the remote host (the plain-SSH respawn path falls back to local execution under the same surface ID; that is why `surface.respawn` is denied).
- **ID params you introduce must be covered by the policy's scoped key sets** (`workspaceIDKeys`, `surfaceIDKeys`, `ambiguousIDKeys`, and the array variants). Adding a new `*_workspace_id`-shaped param name without extending the sets leaves it unscoped.
- **Add policy tests** (`RemoteCLIRelayPolicyTests`) for the new method: the allow case with an owned target, and the deny cases (unmapped target, command params).
- A PR that adds a method to the allowlist without this analysis must be treated as a security regression and blocked in review (enforced by `.github/review-bot-rules/remote-relay-authorization.md`).

## Skills

The [skill index](skills/README.md) lists contributor and installed-app skills. Load the task's skill before changing that area, then only the references you need. Start with [cmux-dev-workflow](skills/cmux-dev-workflow/SKILL.md) for setup/builds or [cmux-testing](skills/cmux-testing/SKILL.md) for verification.
