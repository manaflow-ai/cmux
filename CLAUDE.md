# cmux agent notes

## Initial setup

Run the setup script to initialize submodules, build GhosttyKit, and install the pbxproj normalization pre-commit hook:

```bash
./scripts/setup.sh
```

## Xcode toolchain

The team is pinned to Xcode 26.x; `.xcode-version` is the single source of truth and `cmux.xcodeproj/project.pbxproj` carries `objectVersion = 60` (what Xcode 26 writes by default — bumping it is a deliberate team decision; objectVersion 77 is reserved for synchronized folder groups, which cmux does not use). `scripts/setup.sh` installs a tracked pre-commit hook (`scripts/git-hooks/pre-commit`) that runs `scripts/normalize-pbxproj.py` on staged `project.pbxproj` so Xcode's nondeterministic reordering never reaches a commit; CI runs `scripts/check-pbxproj.sh` to enforce the `objectVersion` pin and normalization (so skipping the hook fails the PR). To bump the pin: edit `.xcode-version`, open the project in the new Xcode (it rewrites `objectVersion` when it touches the file), and add a case mapping that major to its `objectVersion` in `scripts/check-pbxproj.sh`.

## Local dev

After code changes, build the Debug app with a tag. **Never run a bare/untagged build** — an untagged `cmux DEV.app` shares the default debug socket and bundle id with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

`reload.sh` builds but does **not** launch the app; it terminates any running app with the same tag (so cmd-clicking the printed path opens the freshly-built binary). Pass `--launch` to open it automatically. To verify only that the build compiles (no launch), use a tagged derivedDataPath:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<your-tag> build
```

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use that path to build a cmd-clickable `file://` URL. Steps:

1. Grab the path from the `App path:` line in `reload.sh` output.
2. Prepend `file://` and URL-encode spaces as `%20`. Do not hardcode any part of the path.
3. Format it as a markdown link using the template for your agent type.

Example. If `reload.sh` output contains:
```
App path:
  /Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux DEV my-tag.app
```

**Claude Code** outputs:
```markdown
=======================================================
[cmux DEV my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app)
=======================================================
```

**Codex** outputs:
```
=======================================================
[my-tag: file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app)
=======================================================
```

Never use `/tmp/cmux-<tag>/...` app links in chat output.

For CLI or socket dogfood against a tagged Debug app, use the tag-bound helper and set `CMUX_TAG`. Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from `~/Library/Developer/Xcode/DerivedData/cmux-<tag>/...`. It scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the selected tag.

Build/reload scripts:

- `./scripts/reload.sh --tag <tag>` — build the Debug app (tag required) and kill any same-tag app; add `--launch` to also open it. Each tag gets its own name, bundle id, socket, and derived data path, so tagged builds run side by side. Use a non-`/tmp` derived data path when you need xcframework resolution (the script handles this). Before starting a new tagged run, clean up older tags from this session (quit the app, remove its `/tmp` socket/derived data).
- `./scripts/reloadp.sh` — kill and launch the Release app.
- `./scripts/reloads.sh` — kill and launch Release as "cmux STAGING" (isolated from production cmux).
- `./scripts/reload2.sh --tag <tag>` — reload both Debug and Release (tag required for the Debug half).

When rebuilding GhosttyKit.xcframework or cmuxd for release/bundling, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
cd cmuxd && zig build -Doptimize=ReleaseFast
```

## Cloud VM secrets

Cloud VM build, test, and local dev scripts use provider secrets from `~/.secrets/cmux.env`.

- `E2B_API_KEY`
- `FREESTYLE_API_KEY`
- R2 upload vars used by `web/scripts/build-cloud-vm-images.ts` when creating Freestyle snapshots

Load them with:

```bash
set -a
source ~/.secrets/cmux.env
set +a
```

`~/.secrets/cmuxterm-dev.env` is for local Stack/web env and does not contain the provider build keys.
`bun dev` sources `~/.secrets/cmux.env` first when present, then `~/.secrets/cmuxterm-dev.env` so
cmuxterm-specific Stack settings override broader cmux secrets. The web dev loader still accepts
the legacy `~/.secret/cmuxterm.env` and `~/.secrets/cmuxterm.env` paths while machines migrate.

## Backend TypeScript

Default backend TypeScript to Effect. For code under `web/app/api/**`, `web/services/**`, and
backend scripts that touch providers, databases, auth, rate limits, retries, timeouts, or telemetry,
model workflows as `Effect.Effect` values with typed domain errors and explicit service
dependencies. Keep Next route handlers thin: parse the request, run one Effect program at the
boundary, map typed errors to HTTP responses, and treat unexpected defects separately.

Use plain TypeScript only for trivial data shapes, constants, config files, frontend React code, or
small glue where Effect would add ceremony without improving failure handling.

Cloud VM backend logic must stay in Vercel route handlers and Effect services backed by Postgres.
Do not reintroduce Rivet or a raw actor protocol for this feature unless a later architecture doc
explicitly changes the control plane.

Production and staging Cloud VM Postgres should use the Vercel Marketplace AWS Aurora PostgreSQL
OIDC/RDS IAM path. Runtime env names are `CMUX_DB_DRIVER=aws-rds-iam`, `AWS_ROLE_ARN`,
`AWS_REGION`, `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE`. Run production/staging migrations
with `bun db:migrate:aws-rds-iam`; never run Drizzle migrations from Vercel build or route startup.
Local development keeps using the `CMUX_PORT`-derived Docker Postgres path from `bun dev`.
Cloud VM create pricing gates should use Stack Auth team payment items when enabled. Postgres remains
the source of truth for VM lifecycle, active VM limits, idempotency, and usage events.

## Debug event log

When adding debug event instrumentation, put events (keys, mouse, focus, splits, tabs)
in the unified DEBUG build log:

This section describes the required destination and shape for debug logs when they
are added. It is not a blanket requirement to add debug logs to every new code path.
Most temporary probes should be added only during the dogfood debug loop and removed
before merge.

```bash
tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)"
```

- Untagged Debug app: `/tmp/cmux-debug.log`
- Tagged Debug app (`./scripts/reload.sh --tag <tag>`): `/tmp/cmux-debug-<tag>.log`
- `reload.sh` writes the current path to `/tmp/cmux-last-debug-log-path`
- `reload.sh` writes the selected dev CLI path to `/tmp/cmux-last-cli-path`
- `reload.sh` updates `/tmp/cmux-cli` and `$HOME/.local/bin/cmux-dev` to that CLI

- Implementation: `Packages/CMUXDebugLog/Sources/CMUXDebugLog/DebugEventLog.swift`; app shim: `Sources/App/DebugLogging.swift`. Both are `#if DEBUG`, so every call site must be wrapped in `#if DEBUG` / `#endif`.
- Free function `cmuxDebugLog("message")` logs with a timestamp and appends to the file in real time. 500-entry ring buffer; `CMUXDebugLog.DebugEventLog.shared.dump()` writes the full buffer to file.
- Existing instrumentation: key events in `AppDelegate.swift` (monitor, performKeyEquivalent), mouse/UI events inline in views (ContentView, BrowserPanelView, …), and `focus.*` / `tab.*` / `pane.*` / `divider.*` event keys. Grep `cmuxDebugLog` for the current catalog.

## Regression test commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

This makes it visible in the GitHub PR UI (Commits tab, check statuses) that the test genuinely fails without the fix.

## Shared behavior policy

- When a behavior is exposed through multiple entrypoints (keyboard shortcut, command palette, context menu, CLI, settings, debug menu), implement one shared action/model path and verify every entrypoint that should invoke it. Do not patch one surface while leaving the others with duplicated logic.
- For optimistic UI or CLI updates, keep one mutation path, record pending state with a request id or previous snapshot, reconcile from the authoritative result, and handle failure with an explicit rollback or error state. Do not let each entrypoint maintain its own optimistic copy.
- When a user says tests missed a bug, add or adjust behavior-level coverage around the exact repro path before claiming the fix is complete.

## Debug menu

The app has a **Debug** menu in the macOS menu bar (only in DEBUG builds). Use it for visual iteration:

- **Debug > Debug Windows** contains panels for tuning layout, colors, and behavior. Entries are alphabetical with no dividers.
- To add a debug toggle or visual option: create an `NSWindowController` subclass with a `shared` singleton, add it to the "Debug Windows" menu in `Sources/cmuxApp.swift`, and add a SwiftUI view with `@AppStorage` bindings for live changes.
- When the user says "debug menu" or "debug window", they mean this menu, not `defaults write`.

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Typing-latency-sensitive paths** (read carefully before touching these areas):
  - `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`: called on every event including keyboard. All divider/sidebar/drag routing is gated to pointer events only. Do not add work outside the `isPointerEvent` guard.
  - `TabItemView` in `ContentView.swift`: uses `Equatable` conformance + `.equatable()` to skip body re-evaluation during typing. Do not add `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties without updating the `==` function. Do not remove `.equatable()` from the ForEach call site. Do not read `tabManager` or `notificationStore` in the body; use the precomputed `let` parameters instead.
  - `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift`: called on every keystroke. Do not add allocations, file I/O, or formatting here.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`.
- **All user-facing strings must be localized.** Use `String(localized: "key.name", defaultValue: "English text")` for every string shown in the UI (labels, buttons, menus, dialogs, tooltips, error messages). Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese). Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.
- **Localization audit is required for every user-facing change.** Before finishing a task that changes UI, Settings rows, menus, shortcut metadata, schema/config text, docs, command/help text, alerts, or tooltips, enumerate the changed user-facing surfaces and verify each one has entries for every supported locale. `defaultValue`, English fallback text, schema descriptions, or copied English strings do not count as localization. For Swift/AppKit strings, update `Resources/Localizable.xcstrings`; for localized web/docs content, update every supported message catalog (currently `web/messages/en.json` and `web/messages/ja.json`) and any localized data structures that carry inline translations. Parse touched localization files, compare changed message keys across locales, and use `rg` over changed Swift/TS/TSX/docs files for newly introduced bare English. The final handoff must state what localization audit was performed or explicitly say what could not be verified.
- **Shortcut policy:** Every new cmux-owned keyboard shortcut must be added to `KeyboardShortcutSettings`, visible/editable in Settings, supported in `~/.config/cmux/cmux.json`, and documented in the keyboard shortcut and configuration docs.
- **Snapshot boundary for list subtrees.** In any SwiftUI panel whose `body` contains a `LazyVStack` / `LazyHStack` / `List` / `ForEach` of rows, no view below that boundary may hold a reference to an `ObservableObject` / `@Observable` store (no `@ObservedObject`, `@EnvironmentObject`, `@StateObject`, `@Bindable`, or even a plain `let store: SomeStore` property). Rows and drop-gaps receive immutable value snapshots plus closure action bundles only. Violating this reintroduces the "orthogonal @Published change invalidates every row and thrashes `LazyLayoutViewCache`" class of 100% CPU spin loop that hit the Sessions panel and the workspace sidebar (https://github.com/manaflow-ai/cmux/issues/2586). Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **No state mutation inside view-body computations.** A function called from `body` (directly or through a helper) must not write `@Published` state, schedule a `Task { @MainActor in store.x = … }`, or `DispatchQueue.main.async` a store write. That creates a re-render feedback loop and pegs the main thread (same root-cause family as the snapshot-boundary rule). State-changing work triggered by "new data appeared" belongs in a `reload()` completion, a `didSet`, or a property-observer — never in the projection that feeds `ForEach`.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change silently between macOS major versions.** A function that "obviously" returns the same value on every macOS is not a reliable assumption. Concrete case from https://github.com/manaflow-ai/cmux/issues/4529: `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 — Apple silently fixed the underlying CFURL normalization. The repo's `macos-26` CI and every maintainer's dev machine were on the fixed-behavior side; every reporter on the issue was on the broken side. Always test on the reporter's macOS before declaring a user-reported repro disproven. AWS M4 Pro builders (`cmux-aws-mac`, `cmux-aws-m4pro`, `aws-m4pro-1..6`) are pre-provisioned on macOS 15.7.4 and the preferred empirical-repro path; see the `regression-hunt` skill in the cmuxterm-hq sibling repo for the full playbook.
- **Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj`.** A `.swift` file added to the worktree without a matching `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently ignored by Xcode and never compiles or runs on CI. Both `xcodebuild test -only-testing:cmuxTests/<TestClass>` and bot reviews pass with "Executed 0 tests" — so the missing wiring is indistinguishable from a clean two-commit red/green regression test until a real user hits the bug. The `workflow-guard-tests` job runs `./scripts/lint-pbxproj-test-wiring.sh` to catch this at PR time; surfaced during the https://github.com/manaflow-ai/cmux/issues/4529 investigation against https://github.com/manaflow-ai/cmux/pull/4536. Add via Xcode (drag the file into the cmuxTests target) or hand-edit the four pbxproj entries; reference any wired sibling like `TabManagerUnitTests.swift` as a template.

## Package & Swift architecture

cmux is migrating from one app target into Swift Packages under `Packages/`. New or meaningfully-rewritten Swift code (in `Packages/` or the app target) is bound by the architecture, concurrency, testability, file-organization, documentation, and test-framework rules in **[docs/swift-architecture.md](docs/swift-architecture.md)**; the review bots (Codex, CodeRabbit, Greptile) enforce them. The load-bearing summary:

- **Layered, downward-only DAG.** Core (`Sendable` values, IDs, DTOs, protocol seams; no AppKit/IO) → Services (`actor`s, one outside-world capability each) → Domain (`@MainActor @Observable` models + Coordinators, one package per feature) → UI (SwiftUI per domain, never depending on a Service directly) → Executable (`cmuxApp`/`AppDelegate`, a thin composition root and the only place concretes are named). No cycles; a package owns a whole domain, not a slice. Extract leaf-first.
- **Dependency inversion, constructor injection only.** Lower packages publish protocols; higher layers depend on `any Protocol`. No global container, no singleton, no `static let shared` for behavior. Share a type by lifting it to Core or a protocol seam, never a stored property reaching across modules.
- **State is `@Observable`.** Never `ObservableObject`/`@Published`/`@StateObject`/`@ObservedObject`/`@EnvironmentObject`. In views use `@State`, `@Bindable`/`let`, or `@Environment(M.self)`. Decompose god models into child `@Observable` sub-models owned by their domain packages.
- **Modern concurrency.** `actor` + `async`/`await` + `AsyncStream` for new code; no locks, KVO-by-subclassing, Combine, `DispatchQueue` used as a lock, `DispatchQueue.main.async`, completion-handler APIs, or sleep-as-synchronization. `DispatchQueue.asyncAfter` is banned outright. Documented carve-outs (file/socket `DispatchSource`, a bounded injected-`Clock` delay, a synchronous one-shot resume-guard lock, `NSKeyValueObservation`) each need a one-line justification; `@unchecked Sendable`/`nonisolated(unsafe)` need a safety-argument comment.
- **One major type per file**, named after the type; conformances in `TypeName+Feature.swift`. Document every `public` symbol in `Packages/` with a DocC `///` comment at write time.
- **Testable without the app.** Every public package type is constructable in a test target without launching the app, booting AppKit, or touching `UserDefaults.standard`/the real filesystem — inject defaults/filemanager/clock/paths; no global state, no static test hooks.
- **Tests use Swift Testing** (`import Testing`, `@Test`, `#expect`, `try #require`); UI tests stay on XCTest/XCUITest under `cmuxUITests/`.

Full rules, carve-outs, package-wiring mechanics (pbxproj entries), and worked examples: **[docs/swift-architecture.md](docs/swift-architecture.md)**. Tagged dev builds get isolated ExtensionKit sidebar extension points: see **[docs/sidebar-extension-point.md](docs/sidebar-extension-point.md)**.

## Test quality policy

- Do not add tests that only verify source code text, method signatures, AST fragments, or grep-style patterns.
- Do not add tests that read checked-in metadata or project files such as `Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, or source files only to assert that a key, string, plist entry, or snippet exists.
- Tests must verify observable runtime behavior through executable paths (unit/integration/e2e/CLI), not implementation shape.
- For metadata changes, prefer verifying the built app bundle or the runtime behavior that depends on that metadata, not the checked-in source file.
- If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and state that explicitly.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands (`report_*`, `ports_kick`, status/progress/log metadata updates).
- For telemetry hot paths:
  - Parse and validate arguments off-main.
  - Dedupe/coalesce off-main first.
  - Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state (focus/select/open/close/send key/input, list/current queries requiring exact synchronous snapshot) are allowed to run on main actor.
- If adding a new socket command, default to off-main handling; require an explicit reason in code comments when main-thread execution is necessary.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus (no app activation/window raising side effects).
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands, and v1 focus equivalents).
- All non-focus commands should preserve current user focus context while still applying data/model changes.

## Testing policy

**Never run tests locally.** All tests (E2E, UI, python socket tests) run via GitHub Actions or on the VM.

- **E2E / UI tests:** trigger via `gh workflow run test-e2e.yml` (see cmuxterm-hq CLAUDE.md for details)
- **Unit tests:** `xcodebuild -scheme cmux-unit` is safe (no app launch), but prefer CI
- **`reload.sh` does not compile the test target.** It builds only the `cmux` scheme, so a green `reload.sh` says nothing about whether `cmuxTests`/`cmuxUITests` still compile. A symbol that is moved or renamed can keep the `cmux` app building while breaking the test target (real case: a `write(to:atomically:)` typo and a removed `TabManager.CommandResult` only surfaced in the `tests` job). Before pushing package/refactor changes, build the `cmux-unit` scheme (with `-derivedDataPath /tmp/cmux-<tag>` and, for `cmuxApp`/`AppDelegate` churn, the GlobalISel workaround flag) or let the `tests` CI job gate it — never treat `reload.sh` alone as proof the tests build.
- **Python socket tests (tests_v2/):** these connect to a running cmux instance's socket. Never launch an untagged `cmux DEV.app` to run them. If you must test locally, use a tagged build's socket (`/tmp/cmux-debug-<tag>.sock`) with `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`
- **Never `open` an untagged `cmux DEV.app`** from DerivedData. It conflicts with the user's running debug instance.

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = upstream, manaflow = fork
git checkout -b <branch>
git add <files>
git commit -m "..."
git push manaflow <branch>
```

To keep the fork up to date with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Use the `/release` command to prepare a new release. This will:
1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, run `./scripts/release-pretag-guard.sh`, tag, and push

Version bumping:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). The build number is auto-incremented and is required for Sparkle auto-update to work.

Before creating a release tag, run:

```bash
./scripts/release-pretag-guard.sh
```

If it fails, run `./scripts/bump-version.sh`, commit the build-number bump, then retry tagging.

Manual release steps (if not using the command):

```bash
./scripts/release-pretag-guard.sh
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/cmux
```

Notes:
- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `cmux-macos.dmg` attached to the tag.
- README download button points to `releases/latest/download/cmux-macos.dmg`.
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
- Changelog: update `CHANGELOG.md`; docs changelog is rendered from it.
