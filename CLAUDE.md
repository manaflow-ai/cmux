# cmux agent notes

## Database provider

cmux Cloud uses PlanetScale PostgreSQL, organization `cmux`, database `cmux-prod`. Branches are `main` (production), `staging`, and `development`. Vercel uses a PlanetScale `DATABASE_URL`; migration jobs use `DATABASE_URL` and `bun run cloud-vm:migrate -- <target>`. Aurora/RDS IAM and AWS migration-role instructions are retired. AWS KMS access for coderouter encryption is separate from database access. For PlanetScale CLI work, run `pscale auth check --format json` and pass `--org cmux` plus the confirmed branch.

## Setup

`./scripts/setup.sh` initializes submodules, builds GhosttyKit, and installs the pbxproj normalization pre-commit hook.

## Dev builds on the Mac mini fleet

For team dev builds, use the controller client `~/.local/bin/cmux-ci`. The Mac
mini fleet is **dev-build-only** for now. GitHub CI/CD, required checks, merge
queue checks, nightly/release automation, and TestFlight remain on their existing
hosted runners, including Blacksmith. A successful dev build does not replace
those checks.

Before submitting, read the current [HQ AGENTS.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/AGENTS.md)
and [agent build contract](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/AGENT-BUILDS.md).
These are the authoritative fleet instructions even when an old PR worktree has
copied instructions. `AGENTS.md` in this repository is a symlink to this file.

Commit and push the intended edits first. This builds the exact pushed SHA;
it does not upload dirty local edits. Use the PR owner's GitHub login for
`SUBMITTER` (for example `lawrencecchen` or `austinywang`), the full PR URL for
`PR_URL`, and preserve both receipts:

```bash
SHA=$(git rev-parse HEAD)
PR_URL=https://github.com/manaflow-ai/cmux/pull/123
SUBMITTER=lawrencecchen
mkdir -p artifacts/fleet
JOB_JSON=$(~/.local/bin/cmux-ci build cmux --ref "$SHA" \
  --workspace "$PR_URL" --submitter "$SUBMITTER" \
  --receipt "artifacts/fleet/$SHA-submit.json")
JOB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$JOB_JSON")
~/.local/bin/cmux-ci wait "$JOB_ID" --receipt "artifacts/fleet/$SHA-terminal.json" && \
  ~/.local/bin/cmux-ci publish-hq "$JOB_ID"
```

Run `publish-hq` only after `wait` succeeds. Return the job ID immediately to a
requesting agent, then the receipts and HQ download link when complete. If
`wait` times out, wait again on the same ID; do not submit a duplicate. The job
continues if the submitting laptop disconnects. The installed client loads a
private credential file; never print it or copy secrets into PR evidence.

Use the client's workload defaults: **120 GiB for CMUX**, **250 GiB for a cold
Chromium build**. The former blanket 250 GiB CMUX requirement is obsolete.
Do not copy it into new requests or bypass a rejection with an arbitrary lower
floor. A validated Chromium warm profile may use 200 GiB through the runbook's
compatibility-receipt workflow. Report a controller/worker policy mismatch;
queueing is not permission to build over SSH.

The disk daemon owns cleanup under the host lock. Do not remove shared caches,
active workspaces, or other agents' builds to make space. Retain the terminal
receipt's timing, cache, disk, cleanup, and artifact evidence. A cached artifact
replay is not a changed-source warm compilation benchmark.

### Fleet allocation transition

The macfleet skill is retired. Do not load, invoke, reinstall, or follow it.
Do not start new maclease workloads, including `reload-cloud`, `tsadmin builder`,
or `verify-remote` flows that allocate through maclease. Use the controller where
supported and report missing recipe support rather than bypassing scheduling.
Existing jobs may complete and release their reservations. Direct SSH and
`tsadmin` remain available for administration and diagnostics; do not change SSH
keys, Tailscale, or host access as part of this transition.

### Tagged builds outside the team fleet

Reuse the tag's warm DerivedData and published dependencies before a cold
build. For prebuilt GhosttyKit, run `./scripts/download-prebuilt-ghosttykit.sh`,
then use `CMUX_GHOSTTYKIT_PREPROVISIONED=1` with the tagged reload. The download
verifies the pinned artifact. R2 cache transport lives in
[`scripts/ci/r2-cache.sh`](scripts/ci/r2-cache.sh); cache selection, compatibility
checks, and fallback belong in the build tooling.

Always build with a tag. **Never run bare `xcodebuild` or open an untagged
`cmux DEV.app`**: untagged builds share the default debug socket and bundle ID
with other agents. The fleet publishes isolated tags through HQ. Report the
`publish-hq` URL as a Markdown link so HQ can restore/download the build; never
substitute a raw `.app` path or a `file://` URL.

For standalone contributors without the team controller, the local workflow is
`./scripts/reload.sh --tag <branch-slug>` (build without launch) or the same
command with `--launch`. This is not a queue-bypass fallback for team agents.
Other local variants remain `reloadp.sh` (Release), `reloads.sh` (isolated
Release staging), and `reload2.sh --tag <tag>` (both). Local compile-only checks
must use the tagged DerivedData directory rather than an untagged default.
Clean up only tags you own; retain DerivedData while an active task needs it.

Standalone local compile-only check, reusing the tag's DerivedData:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-<tag>" build
```

`<tag>` is the slug `reload.sh` makes: lowercase, with runs of other characters
replaced by `-` (`Fix/ABC-1` becomes `fix-abc-1`). A different path starts a cold
build. When GhosttyKit itself needs rebuilding (see prebuilt reuse above):

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

### Intel Macs, Xcode 16.2, Swift 6.0

The macOS app also builds on Intel Macs running macOS 14 with Xcode 16.2 (Swift 6.0.3), including tagged `./scripts/reload.sh` dev builds; `GhosttyKit.xcframework` already ships fat x86_64+arm64 slices targeting macOS 13. Xcode 26 stays the pinned toolchain (`.xcode-version`) for CI, releases, and the iOS app; this pathway is best effort and changes nothing for Xcode 26. Code linked into the macOS app (`Sources/`, `CLI/`, `TunnelExtension/`, and the packages it depends on) stays within Swift 6.0 syntax: no trailing commas in parameter or argument lists (SE-0439, Swift 6.1), no `nonisolated` on struct/enum/class/protocol declarations (SE-0449, Swift 6.1; member-level `nonisolated` is fine), and the existing `#if compiler(>=6.2)` / `#else @Sendable` split for `@concurrent` (SE-0461 is Swift 6.2; the Swift 6.0 compiler does not implement it and only warns that the attribute was renamed, so it must not be relied on for the 6.2 semantics). macOS 26-only APIs stay behind their `@available`/`#available` checks and are simply unavailable at runtime on macOS 14. `cmuxTests/`, `cmuxUITests/`, and `Packages/iOS/` are outside this pathway.

## Tag-bound debug CLI

For CLI or socket dogfood against a tagged Debug app, set `CMUX_TAG` and use the helper. Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from DerivedData. It scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the tag.

## iOS UI follows the Apple HIG

`Packages/iOS/AGENTS.md` requires consulting the Apple Human Interface
Guidelines for any iOS UI change and citing the page in the PR. It applies to
`Packages/iOS/` and `ios/`.

## iOS builds open on the iPhone by default

Any work verified by opening the iOS app installs BOTH an isolated-simulator build AND the same build on the user's iPhone. Never stop at simulator-only. Use a provisioned, verified controller recipe for the team simulator dev-build leg, following the current HQ runbook. A macOS CMUX build proves neither iOS compilation nor installation. Do not use `ios/scripts/reload-cloud.sh` while it allocates through maclease; report a missing controller recipe. Standalone contributors may use `ios/scripts/reload.sh --tag <tag>`; with a default iPhone configured (`CMUX_IPHONE_DEVICE_ID` or `~/.config/cmux/iphone-device-id`) the device leg is automatic, and `--device-id <id>` still overrides (`xcrun devicectl list devices`). Physical iPhone builds always select the `personal` auth profile. Agent-driven Simulator verification always selects `agent`. Both named profiles live in `~/.secrets/cmuxterm-dev.env`; neither may fall back to the other. The simulator leg uses the tag's own isolated device `cmux-dev-<slug>`, created on demand; do not target a shared or user-visible simulator.

**Every phone install MUST be authenticated before handoff. Installed-but-signed-out is a failed install.** A tagged bundle id can retain an older account, so every authenticated launch clears that tagged session, signs both surfaces into the selected profile, verifies the exact tagged Mac account through `auth status`, then mints the pairing ticket. The iPhone auth gate passes only after the same-account host accepts the phone RPC and emits `mobile.rpc.ready`. `scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>]` repeats the Mac-account check, relaunches the phone without credentials, and passes only when persisted phone state reconnects. Never install with raw `devicectl device install app`, and never pass `--no-sign-in`/`--no-attach`/`--no-setup` for a dogfood build. The scripts refuse those device paths unless a human sets `CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1`. If setup fails, report the gate reason and exact retry command.

Every phone build requires the same-tag Mac dev build (the iOS app is unusable without its Mac). The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the signed build is parked in `scripts/iphone-install-queue.sh`. Each entry stores the chosen profile, normalized account, and credentials-file path. Drain revalidates that snapshot before device mutation and uses installed stable copies of the launcher and auth helpers, so an old or pruned feature worktree cannot change policy. Install or refresh that control plane with `scripts/install-iphone-queue-agent.sh install`. Report `scripts/iphone-install-queue.sh list` in the handoff; `drain` retries delivery and `clear` abandons a queued build.

## iOS and verification capacity

Team iOS simulator dev builds may use only a provisioned and verified controller
recipe. Do not infer simulator, device archive, signing, XCTest, or GUI support
from the macOS recipe or from an idle worker. Preserve the macOS and iOS exact-SHA
receipts separately. Physical-iPhone signing and installation stay local through
the authenticated install queue; signing credentials do not go to shared Macs.
Hosted CI/CD, including TestFlight and scripted XCUITests, remains on the existing
runners, including Blacksmith. Do not migrate those workflows to the mini fleet.

A missing controller verification recipe is a migration gap, not authorization
to revive maclease or run an unscheduled SSH build. For an explicitly authorized
local simulator verification, use an isolated device, never an existing visible
or user-owned simulator, and keep at most three local simulators booted.

## Cross-tag Mac access for DEV iPhone builds

A DEV iPhone build pairs only with the Mac DEV build sharing its tag. When a task needs
the phone to also see other Mac dev builds (multi-Mac verification, dogfooding another
task's Mac from an existing phone build), grant those tags at runtime through the
same-tag Mac's debug socket instead of rebuilding or re-pairing the phone:

```bash
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags add <mac-tag> [more-tags]
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags list
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags remove <mac-tag>
CMUX_TAG=<phone-tag> scripts/cmux-debug-cli.sh mobile compatible-tags clear
```

The grant set persists on that Mac and on the phone (per phone build tag), pushes live
to a connected phone, and otherwise applies on the phone's next connect. Removing a tag
disconnects and hides that Mac on the phone. Release lanes (`default`, `nightly`, `rc`,
`staging`) are never grantable, and only the phone's exact-tag Mac can change its grant
set. Use this whenever the user asks to let another Mac dev build connect to their
iPhone build; do not mint a shared tag or rebuild the phone for that.

## iOS dev auth

`~/.secrets/cmuxterm-dev.env` is the only mobile dev credential file. `CMUX_DOGFOOD_STACK_*` is the `personal` profile for physical iPhone dogfood. `CMUX_UITEST_STACK_*` is the `agent` profile for isolated Simulators. Run `scripts/setup-team-dev.sh` once to verify and merge the personal pair without deleting the agent pair. Use `scripts/mobile-dev-launch.sh --check-auth-contract --auth-profile personal` or `--auth-profile agent` for a mutation-free preflight. Never substitute one profile when the requested profile is incomplete.

## Regression test commits

Two commits, so CI proves the test catches the bug: commit 1 adds the failing test only (CI red), commit 2 adds the fix (CI green). This is visible in the PR Commits tab.

## First pass, then dogfood

A first pass ends when the change is implemented, the tagged build succeeded on the pushed HEAD, focused tests ran, and the PR is open (for `web/` PRs, also the live Vercel preview URL). Then hand off to the user. Do not sit in the main conversation watching CI or running speculative review passes after that point.

Do not launch a background review agent (`$autoreview`, `codex review`, `claude review`, or a judge loop) by default. Second-model review is explicit user opt-in in the current conversation; an implementation request, open PR, CI failure, closeout, or handoff is not that opt-in. Let required GitHub checks and the automatic review bots run asynchronously, then return to address only concrete check failures and actionable findings before merge.

The main agent owns dogfood, approval, mergeability, and every pushed fix. Merging app/runtime/UI changes requires the user's explicit approval after dogfood; if a fix changes runtime behavior mid-dogfood, rebuild the tag and re-notify, since the earlier verdict covers only the build the user tested.

Notify through `cmux notify` so the user can leave and return. Handoff: `--title "Dogfood ready: <short task>" --subtitle "<branch> · <tag>" --body "Was: <prior bad behavior>. Now: <expected behavior>. <concrete check>. PR: <pr-url>"`. Later closeout notifications use `"CI green: <branch>"` or `"CI blocked: <branch>"` with a one-line cause and the next decision. Titles carry outcome and branch, bodies carry the single next action. Skip notify if there is no cmux socket.

## Pitfalls

Each of these has full detail in the skill named in parentheses.

- **Typing-latency-sensitive paths** (`cmux-debugging`): `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`, `TabItemView` in `ContentView.swift`, and `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift` run on every keystroke. Read the skill before touching them.
- **SwiftUI list boundaries** (`cmux-debugging`): no view below a `LazyVStack`/`LazyHStack`/`List`/`ForEach` boundary may hold an observable store reference, and no function called from `body` may write state. Violating either reintroduces the 100% CPU spin loop from https://github.com/manaflow-ai/cmux/issues/2586. Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **Do not add an app-level display link or manual `ghostty_surface_draw` loop.** Rely on Ghostty wakeups and its renderer, or typing lags.
- **Terminal find layering** (`cmux-debugging`): `SurfaceSearchOverlay` mounts from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), never from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- **Submodule safety** (`cmux-ghostty`): push the submodule commit to its remote `main` before committing the pointer in the parent repo. Never commit on a detached HEAD. Verify with `git merge-base --is-ancestor HEAD origin/main`.
- **Localize every user-facing string** (`cmux-localization`): `String(localized:)` with keys in `Resources/Localizable.xcstrings`, plus every web locale declared by `web/i18n/routing.ts` with a matching `web/messages/<locale>.json` entry. The supported macOS app locales are English, German, French, Arabic, Spanish, Traditional Chinese, Simplified Chinese, Korean, and Japanese (`en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`). A localization audit is required for any UI, Settings, menu, schema, docs, or help-text change, and the handoff must state what was audited.
- **Shortcut policy** (`cmux-keyboard-shortcuts`): every new cmux-owned shortcut goes in `KeyboardShortcutSettings`, is editable in Settings, is supported in `~/.config/cmux/cmux.json`, and is documented.
- **Test wiring** (`cmux-testing`): a `.swift` file in `cmuxTests/` without a `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently skipped, and both `xcodebuild test` and bot reviews pass with "Executed 0 tests". `workflow-guard-tests` runs `./scripts/lint-pbxproj-test-wiring.sh` to catch it.
- **SPM package groups** (`cmux-architecture`): packages live under `Packages/{Shared,iOS,macOS}/<pkg>` and the workspace mirrors that folder shape. To move one, `git mv` the directory then `python3 scripts/check-workspace-package-groups.py --write`. Never hand-edit workspace group membership.
- **Do not gitignore cmux-owned `Package.resolved`.** SwiftPM resolution changes must show in PR diffs; package-local lockfiles are not replaced by the root one. `python3 scripts/check-package-resolved-policy.py` fails on drift.
- **"Feature flag" means a remote PostHog runtime flag.** Implement through `CmuxFeatureFlags` with a PostHog key, explicit unavailable fallback, registry metadata, live update behavior, and focused tests. A local override may support dogfood but must not be the production control plane.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change between macOS major versions.** `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 (https://github.com/manaflow-ai/cmux/issues/4529); CI and maintainer machines were all on the fixed side while every reporter was on the broken side. Test on the reporter's macOS before declaring a repro disproven. AWS M4 Pro builders (`aws-m4pro-1..6`) run macOS 15.7.4.

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

Detailed contributor rules live in `skills/`. Use the task-specific skill before changing that area.

- `cmux-dev-workflow`: setup, tagged reloads, Xcode project normalization, sidebar extension tagging, build isolation.
- `cmux-architecture`: package boundaries, file/API discipline, testability, Swift concurrency.
- `cmux-backend`: backend TypeScript, Effect, Cloud VM control plane, provider secrets, Postgres and migrations.
- `cmux-billing`: Stripe checkout, entitlements, webhooks, pricing dev stack, live provisioning.
- `cmux-cloud-vm`: driving cmux Cloud machines from the CLI (`cmux vm` exec/push/pull/wait, ports, checkpoints, forks) and the agent etiquette around them.
- `cmux-debugging`: debug event log, Debug menu, runtime pitfalls, typing-sensitive paths, SwiftUI list boundaries.
- `cmux-localization`: user-facing strings, localization files, shortcut text, localization audit.
- `cmux-testing`: regression policy, Swift Testing, test quality, test wiring, local vs CI validation.
- `cmux-socket-policy`: socket command threading and focus preservation.
- `cmux-shared-behavior`: shared action paths for multi-entrypoint behavior and optimistic updates.
- `cmux-ghostty`: Ghostty submodule and GhosttyKit workflow.
- `cmux-release`: release, version bump, changelog, pretag guard, release assets.
- Blacksmith Testbox (remote Linux builds for cmux-tui): warm your own box before any cmux-tui Rust or Zig
  build, and never compile cmux-tui on the Mac. The skill lives in cmuxterm-hq at
  `skills/infra/blacksmith-testbox/SKILL.md`; the workflows, `scripts/blacksmith-*.sh`, and the
  `tests/test_testbox_*` guards stay here. Quickest path: `./scripts/blacksmith-testbox-demo.sh`.
