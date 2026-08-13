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

## Tag-bound debug CLI

For CLI or socket dogfood against a tagged Debug app, set `CMUX_TAG` and use the helper. Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from DerivedData. It scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the tag.

## iOS builds open on the iPhone by default

Any work verified by opening the iOS app installs BOTH an isolated-simulator build AND the same build on the user's iPhone. Never stop at simulator-only. Use `ios/scripts/reload-cloud.sh --tag <tag>` (or `ios/scripts/reload.sh --tag <tag>`); with a default iPhone configured (`CMUX_IPHONE_DEVICE_ID` or `~/.config/cmux/iphone-device-id`) the device leg is automatic, and `--device-id <id>` still overrides (`xcrun devicectl list devices`). Auto sign-in and auto-pair apply as usual; launch the app so it is immediately open on the phone. The simulator leg uses the tag's own isolated device `cmux-dev-<slug>`, created on demand; do not target a shared or user-visible simulator.

**Every phone install MUST be authenticated before handoff — installed-but-signed-out is a failed install.** A tagged bundle id is a fresh identity with no session, so after EVERY install (first install or rebuild of an existing tag), the app must be past the login screen and paired. This is mechanically enforced, not advisory: device launches default to the full `--ensure-mac` flow, and the **iPhone auth gate** inside `scripts/mobile-dev-launch.sh` exits non-zero (with the exact retry command) unless the tagged Mac observes a signed-in + paired `mobile.rpc.ready` session from the phone. `scripts/verify-iphone-auth.sh --tag <tag> [--device-id <id>]` is the required post-install verification verb when you installed any other way or need to re-check later: it relaunches the app WITHOUT injecting credentials and passes only if persisted sign-in + pairing produce a usable RPC session (PASS/FAIL with reason, no screenshots). Never install with raw `devicectl device install app` (it skips sign-in entirely and the local-build-guards wrapper refuses it for the configured personal iPhone), and never pass `--no-sign-in`/`--no-attach`/`--no-setup` for a dogfood build — the scripts refuse them for device installs unless `CMUX_ALLOW_UNAUTHENTICATED_INSTALL=1` is set, and that variable is **human-only: agents never set it** (same convention as `CMUX_ALLOW_LOCAL_XCODEBUILD`). If sign-in cannot be completed (missing `~/.secrets/cmuxterm-dev.env`, web API down, phone locked), the gate's failure output is the truth: put its reason and retry command in the handoff instead of handing off a logged-out app.

Every phone build requires the same-tag Mac dev build (the iOS app is unusable without its Mac). The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the reload still completes: the signed build is parked in the offline install queue (`scripts/iphone-install-queue.sh`, persistent under `~/Library/Application Support/cmux-dev/iphone-install-queue`), and a LaunchAgent auto-installs and launches it within seconds of the phone being plugged back in or reappearing on the network, then sends a `cmux notify` reporting the TRUE post-install state: a drained install passes the same iPhone auth gate, so the notification says either "installed + VERIFIED signed in" or "installed but SIGN-IN FAILED" with the reason and retry command. An auth-failed drain keeps the entry under `needs-auth/` (never dropped); `scripts/iphone-install-queue.sh retry --tag <tag>` re-queues it after the blocker is fixed. The LaunchAgent is a one-time per-Mac setup: `scripts/install-iphone-queue-agent.sh install`; it runs a stable copy of the queue script, so re-run the installer after changing that script. In the handoff, report the queued state (`scripts/iphone-install-queue.sh list`) instead of treating an unreachable phone as a failure; `drain` retries manually, `clear` abandons a queued build.

## Verification runs on the fleet by default

Agent verification (iOS simulator checks, tagged macOS GUI checks) runs on the Mac mini fleet, not on the local Mac. From the cmuxterm-hq checkout that owns this worktree, `scripts/verify-remote.sh` leases a slot from the verify pool, pushes the tagged build to the leased mini, drives it there (per-lease uniquely named simulator for iOS; console launch with debug-socket and computer-use evidence for macOS), and fetches screenshots, recordings, and logs back into the hq `artifacts/verify-remote/` directory:

```bash
scripts/verify-remote.sh ios --tag <tag>
scripts/verify-remote.sh mac --tag <tag>
scripts/verify-remote.sh capacity
```

Boot a local simulator only when `capacity` reports no free verify slot, and keep at most 3 local sims booted. Scripted XCUITests go through the hosted `test-e2e.yml` lane, not verify slots. The physical-iPhone leg always stays local via the install queue. Verify leases carry a non-empty tag and a TTL, so a crashed agent frees its slot automatically; see `skills/infra/macfleet/references/verify-remote.md` in cmuxterm-hq for pool design and host onboarding.

## iOS dev auth

`ios/scripts/reload.sh` and `scripts/mobile-dev-launch.sh` auto-sign-in from `~/.secrets/cmuxterm-dev.env`. If the phone lands on the login screen or the helper reports missing credentials, do not ask the user to authenticate every build. Tell them to run `scripts/setup-team-dev.sh` once; it verifies their Stack login and writes the file chmod 600. Manual fallback: create it with `CMUX_DOGFOOD_STACK_EMAIL=...` and `CMUX_DOGFOOD_STACK_PASSWORD=...`.

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
- **Localize every user-facing string** (`cmux-localization`): `String(localized:)` with keys in `Resources/Localizable.xcstrings`, plus every web message catalog (`web/messages/en.json`, `web/messages/ja.json`). A localization audit is required for any UI, Settings, menu, schema, docs, or help-text change, and the handoff must state what was audited.
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

## Skills

Detailed contributor rules live in `skills/`. Use the task-specific skill before changing that area.

- `cmux-dev-workflow`: setup, tagged reloads, Xcode project normalization, sidebar extension tagging, build isolation.
- `cmux-architecture`: package boundaries, file/API discipline, testability, Swift concurrency.
- `cmux-backend`: backend TypeScript, Effect, Cloud VM control plane, provider secrets, Postgres and migrations.
- `cmux-billing`: Stripe checkout, entitlements, webhooks, pricing dev stack, live provisioning.
- `cmux-debugging`: debug event log, Debug menu, runtime pitfalls, typing-sensitive paths, SwiftUI list boundaries.
- `cmux-localization`: user-facing strings, localization files, shortcut text, localization audit.
- `cmux-testing`: regression policy, Swift Testing, test quality, test wiring, local vs CI validation.
- `cmux-socket-policy`: socket command threading and focus preservation.
- `cmux-shared-behavior`: shared action paths for multi-entrypoint behavior and optimistic updates.
- `cmux-ghostty`: Ghostty submodule and GhosttyKit workflow.
- `cmux-release`: release, version bump, changelog, pretag guard, release assets.
