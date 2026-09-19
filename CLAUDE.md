# cmux agent notes

## Setup

`./scripts/setup.sh` initializes submodules, builds GhosttyKit, and installs the pbxproj normalization pre-commit hook.

## Build and reload

Always build with a tag. **Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`**: untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <branch-slug>            # build Debug, kill same-tag app, do not launch
./scripts/reload.sh --tag <branch-slug> --launch   # also open it
```

A tag gives the app its own name, bundle ID, socket, and derived data path, so it runs side-by-side with the user's main app. Report the build to the user as a markdown link to `http://127.0.0.1:17320/<tag>`. Never put a `file://` URL, a raw `.app` path, or `/tmp/cmux-<tag>/...` in chat output.

Other variants: `reloadp.sh` (Release), `reloads.sh` (Release as isolated "cmux STAGING"), `reload2.sh --tag <tag>` (both).

Compile-only check, no launch:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

Rebuild GhosttyKit.xcframework with Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

Clean up older tags you started this session (quit the app, remove its `/tmp` socket and derived data) before launching a new one.

### Intel Macs, Xcode 16.2, Swift 6.0

The macOS app also builds on Intel Macs running macOS 14 with Xcode 16.2 (Swift 6.0.3), including tagged `./scripts/reload.sh` dev builds; `GhosttyKit.xcframework` already ships fat x86_64+arm64 slices targeting macOS 13. Xcode 26 stays the pinned toolchain (`.xcode-version`) for CI, releases, and the iOS app; this pathway is best effort and changes nothing for Xcode 26. Code linked into the macOS app (`Sources/`, `CLI/`, `TunnelExtension/`, and the packages it depends on) stays within Swift 6.0 syntax: no trailing commas in parameter or argument lists (SE-0439, Swift 6.1), no `nonisolated` on struct/enum/class/protocol declarations (SE-0449, Swift 6.1; member-level `nonisolated` is fine), and the existing `#if compiler(>=6.2)` / `#else @Sendable` split for `@concurrent` (SE-0461 is Swift 6.2; the Swift 6.0 compiler does not implement it and only warns that the attribute was renamed, so it must not be relied on for the 6.2 semantics). macOS 26-only APIs stay behind their `@available`/`#available` checks and are simply unavailable at runtime on macOS 14. `cmuxTests/`, `cmuxUITests/`, and `Packages/iOS/` are outside this pathway.

## Tag-bound debug CLI

For CLI or socket dogfood against a tagged Debug app, set `CMUX_TAG` and use the helper. Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from DerivedData. It scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the tag.

## Area-specific instructions

Rules that only matter in one part of the tree live next to that code. Read the file before working there; not every agent loads a nested file on its own when launched from the repository root.

- `ios/`, `Packages/iOS/`: `ios/AGENTS.md` (Apple HIG rule, iPhone install and auth gates, cross-tag Mac access, dev auth profiles).
- `web/` and any cmux Cloud database work: `web/AGENTS.md`. The database is PlanetScale PostgreSQL; Aurora/RDS instructions are retired.
- `cmux-tui/`: `cmux-tui/AGENTS.md` (hosted verification, Blacksmith Testbox).
- Maintainers with a `cmuxterm-hq` checkout: the `cmux-mac-fleet` skill covers the shared Mac fleet. Everyone else builds and verifies locally with the commands above.

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
- **Localize every user-facing string** (`cmux-localization`): `String(localized:)` with keys in `Resources/Localizable.xcstrings`, plus every web message catalog (`web/messages/en.json`, `web/messages/ja.json`). The supported macOS app locales are English, German, French, Arabic, Spanish, Traditional Chinese, Simplified Chinese, Korean, and Japanese (`en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`). A localization audit is required for any UI, Settings, menu, schema, docs, or help-text change, and the handoff must state what was audited.
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
- `cmux-mac-fleet`: maintainers only. Leasing the shared Mac fleet for builds and remote verification; needs a `cmuxterm-hq` checkout.
