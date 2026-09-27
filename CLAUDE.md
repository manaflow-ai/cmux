# cmux agent notes

Every agent loads this file on every turn, so it holds only what applies to every task. Setup, build, test and pull request steps for everyone are in [CONTRIBUTING.md](CONTRIBUTING.md). Procedures live in the [skills](skills/README.md) and the area files below.

## Setup and verification

Run `./scripts/setup.sh` once: it initializes submodules, builds GhosttyKit and installs the pbxproj normalization pre-commit hook.

Before committing, setup or a native build, [choose verification for the changed area](skills/cmux-testing/references/local-vs-ci-validation.md). `python3 scripts/verify-local.py` runs the [fast static checks](CONTRIBUTING.md#fast-checks-before-building-or-pushing); docs and portable-tooling changes do not need an app build. The checker executes repository scripts, including those in a `--repo` target, so run it only on code you trust. Nothing runs candidate code on push; see the [trust boundary](docs/contributor-verification.md#trust-boundary).

## Never

- **Never build untagged.** No bare `xcodebuild`, and never open an untagged `cmux DEV.app`: untagged builds share the default debug socket and bundle ID with other agents. Build with `./scripts/reload.sh --tag <branch-slug>` (`--launch` to open it). In a checkout not created through cmuxterm-hq, set `CMUX_DEV_BACKEND_MODE=local`. Reuse the tag's DerivedData and prebuilt GhosttyKit before a cold build, and clean up only tags you own. Compile-only commands, reload variants and GhosttyKit rebuilds: [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md). Team members: the shared build fleet and its rules are in cmuxterm-hq.
- **Never report a raw `.app` path or a `file://` URL.**
- **Never quit, kill (`pkill -x cmux`, `killall cmux`), relaunch or profile the user's running cmux** (`/Applications/cmux.app`, `com.cmuxterm.app`). It holds their live agent sessions. No `xctrace --launch` or Instruments launch, and no Release build or other `com.cmuxterm.app` bundle while it runs. Never set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`, even when a script's refusal message suggests it; only the user sets it. Copy their session into a tagged build to reproduce, and profile by attaching to a tagged pid ([details](skills/cmux-dev-workflow/references/tagged-builds.md#the-users-running-cmux)).
- **Never use `/tmp/cmux-cli` for dogfood.** It points at the most recently reloaded build and can target the user's main app socket. Use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh <command>` ([details](skills/cmux-dev-workflow/references/tagged-builds.md#tagged-cli-and-socket)).
- **Never use syntax newer than Swift 6.0 in code linked into the macOS app** (`Sources/`, `CLI/`, `TunnelExtension/` and their packages). The app also builds with Xcode 16.2 on Intel Macs; the limits are in [Swift 6.0 compatibility](skills/cmux-architecture/references/swift-6-0-compatibility.md).

## Area-specific instructions

Rules that only matter in one part of the tree live next to that code. Read the file before working there; not every agent loads a nested file on its own when launched from the repository root.

- `ios/`, `Packages/iOS/`: `ios/AGENTS.md` (Apple HIG rule, iPhone install and auth gates, local simulators, cross-tag Mac access, dev auth profiles).
- `web/` and any cmux Cloud database work: `web/AGENTS.md` (database provider).
- `cmux-tui/`: `cmux-tui/AGENTS.md` (hosted verification, Blacksmith Testbox).

## Public writing and changelog

Before drafting or revising a top-level issue, PR description, RFC or progress update, read [STYLE.md](STYLE.md).

When a user-visible change merges, add one line under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md) (PR link, `-- thanks @user!` for outside authors).

## Outside contributors

Before fixing a bug or building a feature, run `gh search prs --repo manaflow-ai/cmux --state open '<symptom or issue number>'` and look for an outside PR (author not on the team). If one exists:

- Prefer landing theirs. Push fixups to their branch when "Allow edits by maintainers" is on, and say what you changed.
- If you write your own fix instead, add `Co-authored-by: Name <email>` for them to every commit that uses their approach, using the email from their commits (`git log --format='%an <%ae>'` on their branch). Then comment on their PR with a link to yours and a plain thank-you, and let a human close it.
- Never close an outside PR without a human-written comment saying why.

## CI, review and merge

- **CI labels.** Normal PR CI already runs the suites a diff edits or touches. `full-ci` is not a generic review or merge requirement: add it only when the user or an agreed validation plan asks for the broad suite, and say which extra lanes and why. Check the tests that executed on the current SHA; a green skipped job is not coverage. See [PR CI coverage](skills/cmux-testing/references/pr-ci-coverage.md).
- **Regression test commits.** Commit the failing behavioral regression first, then the fix, and record the same focused command's red and green results ([policy](skills/cmux-testing/SKILL.md#reproduce-and-repair)).
- **Merging main.** Don't merge main yourself: `pr-catch-up.yml` merges green main into open PRs that conflict with it or are red only because of it (label `no-auto-catch-up` opts out, `/catch-up` goes sooner). When you need main locally, use `scripts/merge-main.sh`, not a raw `git merge origin/main`. If a push is rejected because the branch moved, `git pull --no-rebase` and push again; never force-push over the catch-up merge. See [merging main](docs/ci/merge-main.md).
- **First pass, then hand off.** A first pass ends when the change is implemented, scoped verification passed and the PR is open. Do not sit watching CI or running speculative review passes.
- **Review with a subagent before merge** ([cmux-review](skills/cmux-review/SKILL.md)), correctness first. Do not use a second model (`codex review`, `$autoreview`) as a review gate.
- **Merge fast, not blind.** `main` is our nightly: stack fixes, do not revert. Wait for the checks that judge the change and skip slow unrelated lanes; if you merge without them, say on the PR what was not verified.
- **Merge approval.** Merging app, runtime or UI changes needs the user's explicit approval after dogfood, or a direct merge directive that names the merge (`merge`, `merge it`, `auto-merge`; `finish`, `lgtm` and `ship it` are not). Per-change handoff requirements, re-dogfood and merge receipts: [dogfood and merge](skills/cmux-review/SKILL.md#dogfood-and-merge).

Notify with `cmux notify` when a cmux socket is available.

## Pitfalls

Each has full detail in the skill named in parentheses. Load it before touching that area.

- **Typing-latency paths** (`cmux-debugging`): `WindowTerminalHostView.hitTest()`, `TabItemView` and `TerminalSurface.forceRefresh()` run on every keystroke.
- **SwiftUI list boundaries** (`cmux-debugging`): nothing below a `LazyVStack`/`LazyHStack`/`List`/`ForEach` boundary holds an observable store, and nothing called from `body` writes state, or the #2586 CPU spin returns.
- **No app-level display link or manual `ghostty_surface_draw` loop** (`cmux-debugging`); rely on Ghostty wakeups.
- **Terminal find layering** (`cmux-debugging`): mount `SurfaceSearchOverlay` from `GhosttySurfaceScrollView`, never from SwiftUI panel containers.
- **Custom drag-and-drop UTTypes** (`cmux-debugging`) are declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`.
- **OS-version semantics** (`cmux-debugging`): Foundation, SwiftUI, AttributeGraph and WebKit change between macOS majors; test on the reporter's macOS before calling a repro disproven.
- **Submodule safety** (`cmux-ghostty`): push the submodule commit to its remote branch before committing the pointer; never commit on a detached HEAD.
- **Localize every user-facing string** (`cmux-localization`) in all required macOS and web locales, and state the localization audit in the handoff.
- **Shortcut policy** (`cmux-keyboard-shortcuts`): every new cmux-owned shortcut goes in `KeyboardShortcutSettings`, is editable in Settings, works in `~/.config/cmux/cmux.json`, and is documented.
- **Test wiring** (`cmux-testing`): an unwired `cmuxTests/` file is silently skipped ("Executed 0 tests"); run `./scripts/sync-test-wiring` after adding, renaming or deleting one.
- **SPM package groups and lockfiles** (`cmux-architecture`): `git mv` a package, then `python3 scripts/check-workspace-package-groups.py --write`; never hand-edit workspace groups or gitignore cmux-owned `Package.resolved`.
- **"Feature flag" means a remote PostHog runtime flag** through `CmuxFeatureFlags` (`cmux-architecture`); a local override is for dogfood only.
- **Shared behavior** (`cmux-shared-behavior`): a behavior with several entrypoints (shortcut, palette, menu, CLI, settings, debug menu) gets one shared action and mutation path, verified at every entrypoint. When a user says tests missed a bug, add behavior-level coverage of the exact repro before calling it fixed.

## Remote CLI relay authorization (GHSA-9vmv-3hjw-j28c)

Every v2 socket method you add or touch is a potential `cmux ssh` relay payload. `RemoteRelayCommandPolicy` denies every method by default and forwards only an allowlist scoped to objects the remote session owns, with command-bearing params denied (one audited exception, `surface.resume.set`, is covered in the reference below).

- Default is deny, and deny is safe. Allowlist a method only when the remote product flow needs it.
- Before allowlisting, answer in the PR description: can it execute commands or open content on local objects, mutate or destroy objects the remote session does not own, or read local state the remote has no business seeing? Any yes means do not allowlist it; reshape the method or its params.
- Never allowlist a method that spawns or respawns terminals unless you verified in the running app that it executes on the remote host.
- An allowlist addition without this analysis is a security regression and is blocked in review.

New ID params, required policy tests and the full checklist: [remote relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md).

## Skills

The [skill index](skills/README.md) lists contributor and installed-app skills. Load the task's skill before changing that area, then only the references you need. Start with [cmux-dev-workflow](skills/cmux-dev-workflow/SKILL.md) for setup and builds or [cmux-testing](skills/cmux-testing/SKILL.md) for verification.
