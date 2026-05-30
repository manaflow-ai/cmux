# cmux agent notes

## Initial setup

Run the setup script to initialize submodules, build GhosttyKit, and install the pbxproj normalization pre-commit hook:

```bash
./scripts/setup.sh
```

## Xcode toolchain

The team is pinned to Xcode 26.x. `.xcode-version` records the major; `cmux.xcodeproj/project.pbxproj` carries `objectVersion = 60`, which is what Xcode 26 writes by default. (objectVersion 77 is reserved for projects that adopt synchronized folder groups, which cmux does not use yet. Bumping to a different value requires a deliberate team decision.)

`scripts/setup.sh` installs a tracked pre-commit hook (`scripts/git-hooks/pre-commit`) that runs `scripts/normalize-pbxproj.py` on any staged `cmux.xcodeproj/project.pbxproj`, sorting the high-churn sections so Xcode's nondeterministic reordering never reaches a commit. The hook is idempotent. CI runs `scripts/check-pbxproj.sh` to enforce both the `objectVersion` pin and normalization, so anyone who skips the hook (or never ran setup) gets a clear failure on their PR.

`.xcode-version` is the single source of truth. To bump the pin: edit `.xcode-version`, open `cmux.xcodeproj` in the new Xcode (which rewrites `objectVersion` automatically when it touches the file), and add a case for the new Xcode major in `scripts/check-pbxproj.sh` mapping it to the `objectVersion` that major writes.

## Local dev

After making code changes, always run the reload script with a tag to build the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

By default, `reload.sh` builds but does **not** launch the app. The script prints the `.app` path so the user can cmd-click to open it. After a successful build, it always terminates any running app with the same tag (so cmd-clicking launches the freshly-built binary instead of foregrounding the stale instance). Pass `--launch` to open the app automatically after the build:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions --launch
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

For CLI or socket dogfood against a tagged Debug app, use the tag-bound helper and set `CMUX_TAG`.
Do not use `/tmp/cmux-cli` for tagged dogfood, since that symlink points at the most recently
reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the
matching tagged CLI from `~/Library/Developer/Xcode/DerivedData/cmux-<tag>/...`. It also scrubs
ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel
IDs, cmuxd socket, and debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and
`CMUX_BUNDLED_CLI_PATH` for the selected tag.

After making code changes, always use `reload.sh --tag` to build. **Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`.** Untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

If you only need to verify the build compiles (no launch), use a tagged derivedDataPath:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<your-tag> build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

When rebuilding cmuxd for release/bundling, always use ReleaseFast:

```bash
cd cmuxd && zig build -Doptimize=ReleaseFast
```

`reload` = build the Debug app (tag required) and terminate any running app with the same tag. Pass `--launch` to also open the freshly-built app:

```bash
./scripts/reload.sh --tag <tag>
./scripts/reload.sh --tag <tag> --launch
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reloads` = kill and launch the Release app as "cmux STAGING" (isolated from production cmux):

```bash
./scripts/reloads.sh
```

`reload2` = reload both Debug and Release (tag required for Debug reload):

```bash
./scripts/reload2.sh --tag <tag>
```

For parallel/isolated builds (e.g., testing a feature alongside the main app), use `--tag` with a short descriptive name:

```bash
./scripts/reload.sh --tag fix-blur-effect
```

This creates an isolated app with its own name, bundle ID, socket, and derived data path so it runs side-by-side with the main app. Important: use a non-`/tmp` derived data path if you need xcframework resolution (the script handles this automatically).

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

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

- Implementation: `Packages/CMUXDebugLog/Sources/CMUXDebugLog/DebugEventLog.swift`
- App shim: `Sources/App/DebugLogging.swift`
- Free function `cmuxDebugLog("message")` — logs with timestamp and appends to file in real time from cmux code
- The package implementation and app shim are `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `CMUXDebugLog.DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`

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
- **Shortcut policy:** Every new cmux-owned keyboard shortcut must be added to `KeyboardShortcutSettings`, visible/editable in Settings, supported in `~/.config/cmux/cmux.json`, and documented in the keyboard shortcut and configuration docs.
- **Snapshot boundary for list subtrees.** In any SwiftUI panel whose `body` contains a `LazyVStack` / `LazyHStack` / `List` / `ForEach` of rows, no view below that boundary may hold a reference to an `ObservableObject` / `@Observable` store (no `@ObservedObject`, `@EnvironmentObject`, `@StateObject`, `@Bindable`, or even a plain `let store: SomeStore` property). Rows and drop-gaps receive immutable value snapshots plus closure action bundles only. Violating this reintroduces the "orthogonal @Published change invalidates every row and thrashes `LazyLayoutViewCache`" class of 100% CPU spin loop that hit the Sessions panel and the workspace sidebar (https://github.com/manaflow-ai/cmux/issues/2586). Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **No state mutation inside view-body computations.** A function called from `body` (directly or through a helper) must not write `@Published` state, schedule a `Task { @MainActor in store.x = … }`, or `DispatchQueue.main.async` a store write. That creates a re-render feedback loop and pegs the main thread (same root-cause family as the snapshot-boundary rule). State-changing work triggered by "new data appeared" belongs in a `reload()` completion, a `didSet`, or a property-observer — never in the projection that feeds `ForEach`.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change silently between macOS major versions.** A function that "obviously" returns the same value on every macOS is not a reliable assumption. Concrete case from https://github.com/manaflow-ai/cmux/issues/4529: `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 — Apple silently fixed the underlying CFURL normalization. The repo's `macos-26` CI and every maintainer's dev machine were on the fixed-behavior side; every reporter on the issue was on the broken side. Always test on the reporter's macOS before declaring a user-reported repro disproven. AWS M4 Pro builders (`cmux-aws-mac`, `cmux-aws-m4pro`, `aws-m4pro-1..6`) are pre-provisioned on macOS 15.7.4 and the preferred empirical-repro path; see the `regression-hunt` skill in the cmuxterm-hq sibling repo for the full playbook.
- **Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj`.** A `.swift` file added to the worktree without a matching `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently ignored by Xcode and never compiles or runs on CI. Both `xcodebuild test -only-testing:cmuxTests/<TestClass>` and bot reviews pass with "Executed 0 tests" — so the missing wiring is indistinguishable from a clean two-commit red/green regression test until a real user hits the bug. The `workflow-guard-tests` job runs `./scripts/lint-pbxproj-test-wiring.sh` to catch this at PR time; surfaced during the https://github.com/manaflow-ai/cmux/issues/4529 investigation against https://github.com/manaflow-ai/cmux/pull/4536. Add via Xcode (drag the file into the cmuxTests target) or hand-edit the four pbxproj entries; reference any wired sibling like `TabManagerUnitTests.swift` as a template.

## Package architecture

We are migrating cmux from a single app target into Swift Packages under `Packages/`. Every new package must satisfy three rules:

- **Ergonomic.** Public API surface matches what callers naturally want to write. Default to internal access; expose `public` only for types and functions that downstream consumers actually use. Avoid friction such as forcing every call site through a builder or wrapper when a direct API is fine.
- **No dependency cycles.** Packages form a strict DAG. A package may only depend on packages strictly lower in the graph. When two packages need to share a type, lift it to a common lower-level package or define a protocol seam in the consumer. Every new dependency edge requires re-checking that the graph stays acyclic.
- **Clear but not overly narrow responsibilities.** A package owns one full domain (e.g. _settings_, _appearance_, _workspace_, _terminal_, _browser_, _command palette_), not a slice of one. A package called "appearance math" or "workspace model" is too narrow — it forces every consumer that touches the surrounding domain to also depend on the sibling slices. Prefer a single `CmuxAppearance` that owns settings, theming, colors, glass, and snapshots together, over `CmuxAppearanceMath` + `CmuxAppearanceTheme` + `CmuxAppearanceSettings`. Don't fragment a domain into `CmuxFooFormatting` + `CmuxFooLogic` + `CmuxFooState` — that's folder structure inside a single package, not module structure. A package boundary exists because more than one consumer needs the contents, or a build/test seam needs to exist.

When in doubt, **extract leaf-first**: pull out the package that has no internal dependencies. Consumers in the app target stay put and only update imports. Each leaf shrinks the app target without requiring downstream packages to exist yet.

The existing packages under `Packages/` predate this policy and should not be used as design references.

## File organization

One major type per file. Each `struct`, `class`, `enum`, `actor`, or `protocol` that is part of a public API (or has any meaningful body) lives in its own file named after the type (`Control.swift`, `LabeledChoice.swift`, `ListControl.swift` — not one shared `SettingControl.swift`). This rule applies to all new code in `Packages/` and to any new files added to the app target.

- Small, closely-bound helpers (`private struct`, nested types, single-line extensions used only inside the file) can stay with the parent type. Anything bigger or independently meaningful gets its own file.
- Conformance-adding extensions for a type defined elsewhere go in `TypeName+Conformance.swift` or `TypeName+Feature.swift`, not bundled into the consuming feature file.
- Type-erased wrappers (`AnyFoo`) live next to the type they erase (`Foo.swift` and `AnyFoo.swift`), each in its own file.
- Existing god files (`ContentView.swift`, `Workspace.swift`, `TabManager.swift`, `cmuxApp.swift`) are the pattern this rule exists to stop. When migrating code out of them, split into one file per type even if it triples the file count. File count is cheap; "find this type" being unanswerable is expensive.

## Documentation

Every `public` symbol in any new Swift package under `Packages/` is documented with a Swift-DocC triple-slash comment at the time of writing. Treat docs as part of the API surface, not as follow-up work.

- **Format.** Use `///` doc comments above the symbol. First line is a one-sentence summary that fits on a single line and ends with a period. If more context is needed, leave a blank `///` line, then add a discussion paragraph. Use `- Parameter name:` / `- Returns:` / `- Throws:` callouts on `init` and `func` symbols that take parameters or throw. Use Markdown freely (bold, fenced code blocks for examples, backticks for inline code).
- **Cross-references.** Refer to other symbols using double-backticks: `` ``CmuxSetting`` ``. Plain backticks are for non-symbol code (`UserDefaults.standard`, `@AppStorage`).
- **What to document on each symbol.** Types: what they represent and when to use them. Enums: meaning of each case. Init parameters: especially defaults and the reason for them. Properties: what value they hold and any invariants. Methods: what they do, plus parameters/returns/throws. Generic constraints: which `Value` / `Element` shapes the type accepts and why (e.g., `Sendable & Codable`).
- **Examples.** Non-trivial APIs get at least one example in a fenced ` ```swift ` block, ideally a real declaration from this codebase. Keep examples short and idiomatic.
- **Internal vs public.** `internal` and `private` symbols get a one-line `///` when the intent is non-obvious; verbosity is not required at that scope. The public boundary is the one that needs full coverage.
- **No stale docs.** When you change a symbol's behavior or signature, update its doc comment in the same edit. Docs that describe last week's behavior are worse than no docs.
- **Don't comment-narrate the body.** Doc comments describe the contract from the outside. Inline `//` comments inside method bodies are reserved for non-obvious *why*, not *what* (the existing rule from the top-level guidance still applies).

This rule applies to all packages under `Packages/`. Code in the main app target is not retroactively required to be documented, but new `public` symbols added to packages must be.

## Package design discipline

These are the recurring design mistakes that have to be caught at the design step, not at code review:

- **No shared-singleton accessors.** `static let standard` / `shared` / `default` on a package type that holds runtime state is a singleton-by-another-name. Construct the package type at the app's startup site and inject it. `static let` is fine for *declarations* — identifiers, schema entries, enum cases — but not for behavior.
- **No namespace-enums.** `enum Foo { static func bar() }` (a no-case enum used as a namespace) is a fake namespace that fights the rest of the design (no instances, no DI, no test seam). Prefer a value-typed struct passed via constructor when the helper might gain configuration, or a file-scope `private func` for pure helpers internal to one file.
- **No parallel hand-maintained registries.** When a list mirrors a set of declared items (e.g. `catalog.all` mirroring the catalog's stored properties), derive the list via `Mirror` reflection or a macro. Two sources of truth drift silently; the IDE doesn't tell you.
- **Prefer compile-time invariants to runtime traps.** If the pattern is `guard ... else { assertionFailure(...); return default }` for a "programmer error" case, encode it in the type system (phantom types, separate concrete flavors). Runtime traps become silent fallbacks in release builds.
- **File-scope `private func` is not `private static func`.** `private static` inside a type signals "this operation belongs to the type." File-scope `private func` signals "pure helper local to this file, unrelated to any type." Use the latter for recursive helpers that take a sliced view as input and never read host-type state.
- **Nested types still count for the one-major-type-per-file rule.** A `private final class WatcherAttachment` inside `JSONConfigFileWatcher.swift` is a major type. Move it to its own file the moment it has a meaningful body.

## Testability

Every public type added to `Packages/` must be **testable from a test target** without launching the app target, without booting AppKit, and without depending on the user's filesystem or `UserDefaults.standard`. Production-grade designs surface a test seam at every boundary:

- **No global state in package code.** Every public type that needs `UserDefaults`, `FileManager`, an on-disk path, an environment variable, or a clock takes it via initializer parameter. Tests pass a `UserDefaults(suiteName:)` scoped to the test, a temp directory URL, a fixed `Date`, etc.
- **No reliance on `.shared` / `.standard`.** A public type that hardcodes `UserDefaults.standard` or `FileManager.default` inside its implementation cannot be tested without polluting the developer's actual settings. Inject these at the seam.
- **Public APIs return values, not side effects, where possible.** A function that mutates global UserDefaults and returns `Void` is harder to test than one that returns the changed value and lets the caller persist. Prefer pure transformations + thin imperative layers.
- **Asynchronous APIs surface their observation as `AsyncStream`.** Tests can iterate `AsyncStream` deterministically and assert the sequence of yielded values. Avoid `NotificationCenter`-only patterns where the test has to spin a runloop.
- **Document the test pattern** alongside any non-trivial public surface. The package's `README.md` and any DocC catalog should show how to instantiate the type with test-friendly dependencies.

If a design is hard to test, it is wrong. Reach for the constructor parameter list, not the test bench.

## Modern Swift concurrency

All new code in `Packages/` and any new files added to the app target use Swift 6 concurrency primitives: `actor`, `async`/`await`, `AsyncStream`/`AsyncSequence`, `@Observable`, `@MainActor`. Old primitives — locks, manual KVO, `@Published`, completion handlers, `DispatchQueue` used as a serial lock — are not allowed.

If you find yourself reaching for a lock, the type is the wrong shape. Promote it to an `actor`.

**Forbidden in new code (no exceptions without a written justification in the PR description):**

- **Locks.** `NSLock`, `NSRecursiveLock`, `os_unfair_lock`, `OSAllocatedUnfairLock`, `pthread_mutex_t`, `Synchronization.Mutex`, `DispatchSemaphore` used as a lock. Use `actor` isolation. Mutable shared state belongs in an actor; reads and writes are `async`.
- **KVO via `NSObject` subclassing.** Any `class Foo: NSObject` whose purpose is to override `observeValue(forKeyPath:...)` or call `addObserver(_:forKeyPath:...)`. Replace with `NotificationCenter.default.notifications(named:)` `AsyncSequence`, or the `NSKeyValueObservation` token API at the seam only.
- **`DispatchQueue` used as a synchronization primitive.** A `DispatchQueue(label:)` accessed via `queue.sync { ... }` to serialize mutable state is a lock with different syntax. Use an `actor`. Queues are fine for *event delivery* (e.g. a `DispatchSource` handler), not for protecting state.
- **Combine for change propagation.** No `@Published`, no `ObservableObject`, no `PassthroughSubject`/`CurrentValueSubject`, no `AnyCancellable` for change observation. Use `@Observable` (Observation framework, Swift 5.9+) for SwiftUI state, or `AsyncStream`/`AsyncSequence` for cross-actor change propagation.
- **Completion-handler APIs.** Authoring a new public API with a `(Result<T, Error>) -> Void` or `(T?, Error?) -> Void` callback is forbidden. Use `async throws -> T`. When wrapping a legacy callback at the boundary, use `withCheckedContinuation`/`withCheckedThrowingContinuation` and keep it confined to that one seam.
- **`DispatchQueue.main.async { ... }`.** Annotate the destination with `@MainActor`. Call sites either `await` the main-isolated function or are themselves `@MainActor`.
- **`Task.sleep` in app/runtime code.** Already forbidden by the cmuxterm-hq top-level rule against sleep-based timing. Allowed in tests only.

**Required shape:**

- Mutable shared state → `actor`. Reads/writes/reset are `async`. Observers receive `AsyncStream` returned by the actor.
- SwiftUI view-render-friendly state → `@Observable @MainActor` view-model that subscribes to the actor's `AsyncStream` and projects snapshots. Don't read actor state synchronously from view code.
- Cross-process / cross-thread invariants → expressed via actor isolation, not via locks or queues.
- New public observable surfaces → `AsyncStream` or `AsyncSequence`. Not callbacks, not `@Published`, not raw `NotificationCenter` subscription.

**Acceptable with a one-line justification comment on the declaration:**

These low-level primitives have no async-native replacement. They must be hidden behind an `AsyncStream` or `actor` surface; callers never see them.

- `DispatchSource.makeFileSystemObjectSource` for file watching (no Foundation async equivalent).
- `DispatchSource.makeReadSource`/`makeWriteSource` for low-level socket I/O.
- `NSKeyValueObservation` token (the closure-based API) when wrapping a Foundation/AppKit type that exposes change only via KVO.

**`@unchecked Sendable` and `nonisolated(unsafe)`:**

Both require a comment on the declaration explaining the safety argument. Examples that pass review:

```swift
// Wraps DispatchSourceFileSystemObject; every mutation happens on `queue`.
private final class WatcherAttachment: @unchecked Sendable { ... }

// UserDefaults is Apple-documented thread-safe; OK to read nonisolated.
private nonisolated(unsafe) let defaults: UserDefaults
```

Without a justification comment, the diff is rejected. `@unchecked Sendable` on an entire actor or struct is almost always wrong; prefer `nonisolated(unsafe) let` on the single non-Sendable property.

**Scope and enforcement:**

- Applies to: every new file in `Packages/`, every new file in the app target, every meaningful rewrite of an existing Swift file.
- Existing app target code may continue to use the old primitives until rewritten. Do not retrofit blindly.
- Code review checklist (Codex, CodeRabbit, Greptile, and human reviewers): reject diffs that introduce `NSLock`/`NSRecursiveLock`/`@Published`/`ObservableObject`/`DispatchQueue.main.async`/`addObserver(_:forKeyPath:...)`/`Task.sleep` outside tests in new code. Reject `@unchecked Sendable` or `nonisolated(unsafe)` without a justification comment.

## Test quality policy

- Do not add tests that only verify source code text, method signatures, AST fragments, or grep-style patterns.
- Do not add tests that read checked-in metadata or project files such as `Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, or source files only to assert that a key, string, plist entry, or snippet exists.
- Tests must verify observable runtime behavior through executable paths (unit/integration/e2e/CLI), not implementation shape.
- For metadata changes, prefer verifying the built app bundle or the runtime behavior that depends on that metadata, not the checked-in source file.
- If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and state that explicitly.

## Test framework

Swift Testing is the current Apple-supported primitive for tests on this codebase (shipped with Swift 6 / Xcode 16, supported on the macOS versions we target). Use it for everything that is not a UI test.

- **Default to Swift Testing for all unit and integration tests.** `import Testing`, annotate tests with `@Test`, group with `@Suite`, assert with `#expect(...)` and `try #require(...)`. Do not write new tests with `import XCTest` unless they are UI tests.
- **UI tests stay on XCTest / XCUITest.** Swift Testing does not support UI testing (no `XCUIApplication` integration). Files under `cmuxUITests/` continue to use `XCTestCase` + `XCUIApplication`. Do not migrate them and do not try to bridge Swift Testing into UI tests.
- **New test targets start on Swift Testing.** Every new Swift package's `Tests/<Name>Tests/` directory (e.g. `Packages/CmuxSettings/Tests/CmuxSettingsTests/`) should ship with Swift Testing from the first commit. Xcode 16 auto-detects the framework based on the `import Testing` statement; no extra `Package.swift` configuration is required.
- **Migration guide when touching an existing XCTest test.** Convert in place: `XCTestCase` subclass becomes a `@Suite struct` (or `final class` if you need a reference type); each `func testFoo()` becomes `@Test func foo()`; `XCTAssertEqual(a, b)` becomes `#expect(a == b)`; `XCTAssertTrue(cond)` becomes `#expect(cond)`; `XCTUnwrap(x)` becomes `try #require(x)`; `XCTFail("msg")` becomes `Issue.record("msg")`. `setUp()` becomes `init()` on the suite; `tearDown()` becomes `deinit`. Async setup is `async init()`. Do not bulk-rewrite untouched tests; migrate incrementally as a side effect of editing the file.
- **Parameterized tests** use `@Test(arguments: [...])`. Prefer this over duplicate test methods.
- **Parallelization and shared state.** Swift Testing runs tests in parallel by default, including across suites. If a suite genuinely needs ordering or guards shared mutable state, annotate it with `.serialized` instead of adding locks or sleeps.
- **Tags** with `@Test(.tags(.something))` (or on a `@Suite`) let CI and local runs filter selectively.

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
