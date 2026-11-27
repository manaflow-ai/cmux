# Mac app (Swift) agent instructions

For `Packages/macOS/`, the `Packages/Shared/` packages the Mac app uses, `App/`, `Native/` and `cmux.xcodeproj`.
The root [CLAUDE.md](../../CLAUDE.md) still applies: never build or test on the person's Mac.

## Where things live

- `macOS/CmuxNext`: all app code, one SwiftPM target per feature under `Sources/`, tests under `Tests/`. The
  comment at the top of its `Package.swift` lists every module and its dependency direction; read it first.
- `macOS/CmuxUpdater`: the Sparkle driver. `macOS/CmuxRemote`: the separate "cmux Remote.app" that holds the
  Accessibility and Screen Recording grants ([docs](../../docs/cmux-remote.md)). `macOS/CmuxPhonePush`: push
  payload crypto; only the retired `ios/` app imports it.
- `Shared/`: the `.package(path: "../../Shared/...")` lines in CmuxNext's `Package.swift` are the ones the app uses.
- `App/main.swift` is the stub of the one Xcode target, `cmux-next`. A new module is a target in `Package.swift`,
  never a `cmux.xcodeproj` edit. `Native/` is Rust: `DiffSidecar` (diff viewer), `OptChat` (the Home Chief).
- Rust core: `CCmuxAppFFI` from `cmux-tui/crates/cmux-app-ffi`, pinned in `CmuxNext/app-ffi-pin.json` (re-pin below).

Where a typical change goes:
- A setting: a row in `schemas/settings/source/<section>.json`; the build writes its Swift, nothing to commit
  ([checklist](../../plans/cmux-next/settings-surfaces.md#agent-checklist)). The PR autofix regenerates the exports.
- A window or panel: AppKit in its feature module, wired in `CmuxNextApp` (`AppServices+*.swift`). New SwiftUI is
  refused (`scripts/cmux-next/check-no-swiftui.py`). The settings window is `CmuxNextSettingsWindow`.
- A menu item is an action: title, shortcut and placement in Rust (`cmux-tui/crates/cmux-action-catalog`), handler via
  `ActionRegistry.bind`, placed by `CmuxNextApp/MainMenu.swift`. `HandlerCoverageTests` fails a missing handler.
- The theme: `Shared/CmuxTheme` (`ThemeTokens`), `CmuxNextDesign` (`Palette`), looks in root `Resources/theme-files/`
  ([recipes](../../docs/cmux-next/theme-recipes.md)). `schemas/theme/chrome-layer-colors.json` needs `Chrome-Look-OK:`.

Decided, do not rebuild the other side: Home, the Chief panel and native chrome are Swift, the agent chat is React,
logic is Rust ([which layer](../../plans/cmux-next/language-layers.md)). Other decided forks (first run is a card on
Home, launch reopens where you were) and their reasons: cmuxterm-hq `decisions/junctions.md`.

## Check a change in five minutes (from a Linux lane VM)

Push first: the fleet builds the pushed SHA. "here" is the lane VM. Running the app needs a Mac; a web or daemon
change needs no app build there (`cmux app try .`, or `cmux-ci hot-verify N --look` from here).

| What | Command | Where |
|---|---|---|
| Static gate (scanners, ast-grep, SwiftFormat, SwiftLint) | `python3 scripts/cmux-next/prepush-gate.py` | here, seconds |
| App compiles and links (Debug) | `cmux-ci compile-check --ref SHA --app` | fleet, about 1 min |
| A package and its tests compile | `cmux-ci compile-check --ref SHA --package CmuxNext` | fleet, 490 s; other packages 26-47 s |
| Package lists and imports; namespaces | `python3 scripts/cmux-next/check-package-dependency-lists.py`; `./scripts/lint-ios-package-conventions.sh` | here, 10 s; 50 s |
| New files in their language | `git diff -z --name-status -M origin/feat-cmux-next... > /tmp/f; python3 scripts/ci/language_boundaries.py --files /tmp/f --format git-z` | here |
| Xcode project, lockfiles | `bash scripts/check-pbxproj.sh`, `python3 scripts/check-package-resolved-policy.py` | here |

On a Mac, Swift that only changes function bodies goes into a running app with no build: `cmux live start --swift`.

## Targeted tests

One suite or test, on a fleet Mac: `cmux-ci run --class light --script scripts/ci/package-test-lane.sh --ref SHA
--arg=suite --arg=Packages/macOS/CmuxNext --arg=CmuxNextSettingsTests` (filter `TARGET`, `TARGET.Suite` or
`TARGET/test`; a comma list runs after one build). `cmux-ci test` runs Linux, only for the packages in
`scripts/ci/swift-linux-packages.txt`. The whole `cmux-next swift test` job took 28 min.

## What CI gates a Mac Swift PR

`cmux-next.yml` routes by path ([tiers](../../docs/ci/cmux-next-tiers.md)): `cmux-next checks`, `cmux-next app compile
(build fleet)`, `cmux-next Swift canary`, `cmux-next generated files`; with `full-ci` also `cmux-next swift test`,
`cmux app scheme compile (Debug)`, `cmux-next Release compile (Xcode 26)`. The `language-boundaries` workflow runs on
every PR into `feat-cmux-next` or `main`. Common reds:
- Dependency list unsorted or import undeclared: `check-package-dependency-lists.py --fix` / `--fix-imports`.
- New Swift in `CmuxNextCloud` or `CmuxNextCloudCredentials` (`.github/language-boundaries.toml`): write it in Rust.
  Only Leo's `leo-approved-port` label passes it; agents never add it.
- Namespace enum or all-static type: `./scripts/lint-ios-package-conventions.sh --namespace-fix`. SwiftUI import:
  use AppKit. File past its god-file cap: split it by type (`scripts/cmux-next/check-no-godfiles.sh`).
- "Check the app FFI pin": FFI sources differ from the pin (`scripts/cmux-next/check-app-ffi-pin.sh`). After the Rust
  merges, `app-ffi-release.yml` re-pins. Never hand-edit `app-ffi-pin.json` ([app FFI release](../../docs/ci/app-ffi-release.md)).
- `cmux.xcodeproj`: `scripts/normalize-pbxproj.py` fixes order; a built file in no group goes in its siblings' group
  (`check-pbxproj-group-membership.py`). Changed package pins need their `Package.resolved` in the same PR
  (`check-package-resolved-policy.py`). No job runs these two on a `feat-cmux-next` PR: run them yourself.

## Deeper docs

[code rules](../../docs/cmux-next/code-rules.md), [live code](../../docs/cmux-next/live-code.md), [hot reload](../../docs/cmux-next/hot-reload.md),
[architecture](../../skills/cmux-architecture/SKILL.md). Jobs and tests a diff starts: `python3 scripts/ci/affected_tests.py`.
