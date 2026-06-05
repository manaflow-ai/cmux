# Xcode project pane — autonomous iteration log

Three reviewers per pass: design/UX, product/PM, technical/Swift. Their prioritized findings drove the per-iteration edits below. All builds green, tests green, screenshots under `iterN-{files,targets,buildSettings,schemes}.png`.

## Iteration 0 — baseline
Foundation slice from earlier in the session: `CMUXProjectModel` package with `XcodeProjectAdapter` (XcodeProj-backed), `ProjectPanel` + four SwiftUI tab views, `project.open` and `project.set_*` / `project.get_state` debug RPCs, session persistence, CLI subcommand. Build green.

## Iteration 1 — top findings applied
- Fix T1 crash: `ProjectTargetsTabView.metadata(_:_:)` returned `Text(...).foregroundStyle(.secondary) as! Text`, a force-cast that crashes the first time it renders. Now `@ViewBuilder some View`.
- Honesty T3: renamed Build Settings "Resolved" column to "Effective" and added disclaimer that xcconfig + platform defaults are not yet folded in.
- Empty states S5: extracted shared `ProjectEmptyDetailView` (icon + title + hint), replacing 12pt floating-secondary "Select a file" / "target" / "scheme" in three tabs.
- Chrome S1: collapsed two-row chrome into one row (project title + scheme + config + reload), tab strip on its own line, path moved to tooltip on title.

## Iteration 2 — segmentation + cleanup
- Tab strip S2: turned from underline-style text into segmented control (selected = filled accent, others = neutral pill).
- Default expansion: auto-collapse Files tree past depth 1 so the top-level navigator opens to a usable summary instead of an alphabetical wall.
- Build Settings P3: added "Customized only" checkbox toggle.
- Targets P5 / S4: dropped the dead Configurations subsection that duplicated Build Settings data.
- Persistence: lifted `collapsedNodeIDs` + `settingsCustomizedOnly` from view `@State` into `ProjectPanel`, so reload doesn't drop tree expansion state.
- Reload race fix: `ProjectPanel.reload()` now cancels in-flight `Task.detached` on re-entry; error path keeps previous model loaded instead of dumping the user back to a status screen.

## Iteration 3 — table polish + filter
- Files P1 / P3: file filter bar at top of Files tab (magnifier + clear button + match count). Filter mode auto-expands matching groups.
- Files P2: single-pane layout when nothing selected (no dead 220pt right-rail). Only splits when a file is selected.
- Targets / Schemes detail polish: replaced the dead Configurations subsection with a count summary + "Open in Build Settings" jump button.
- Bug C4: dropped the hardcoded "Debug" fallback in Build Settings; now uses `module.configurationNames.first ?? ""`.
- Bug C3: Build Settings now resolves the owning module of the selected target (was wrong on multi-module workspaces — was reading module 0's settings while the picker showed module 0's targets).
- `lastLoadError` stale: clears on next successful `applyLoaded` (was lingering as phantom failure).

## Iteration 4 — visual differentiation of overrides
- Build Settings S3: target overrides now stand out with three combined cues — leading 3pt accent bar, accent-colored Target column value, semibold setting name. (Toned down in iter5 — see below.)
- Build Settings hot path C1/C2: hoisted `let rows = ...` at top of body so `Text("\(rows.count) settings")` and `ForEach(rows)` share one evaluation. Same pattern applied to Files tab `flattenedRows`.

## Iteration 5 — bug sweep + tone-down overrides
- Chrome T1: scheme + configuration pickers now `flatMap` across all `model.modules` and dedupe by name (was reading only `model.modules.first`, silently dropping workspace-wide schemes).
- `applyLoaded` T3: validates persisted selections (`selectedSchemeName`, `selectedConfigurationName`, `selectedTargetID`, `selectedFilePath`) against the freshly loaded model; clears + reseeds anything stale to avoid silent wrong-data display.
- Scheme T4: `XcodeProjectAdapter.schemeSummary.resolve(...)` no longer fabricates `TargetID`s from `blueprintIdentifier` when that UUID isn't in the known target set. Returns nil (which the Schemes view now treats as "not in this module's targets") instead of synthesizing 6-char-hash-rendered fake IDs.
- Visual reduce: dropped the semibold-name + accent-Effective combo (too many override signals stacked); kept just the leading bar + accent Target value.

## Iteration 6 — collapse + dedup
- Default expansion (initial): tightened to depth 0 (only root open). Reverted in iter7 after PM agent flagged it as "Files tab is empty."
- Restored: Files tab default expansion back to depth 1.
- Schemes dedup: switched `ForEach(model.modules)` / `ForEach(module.schemes)` to a single `ForEach` over `[(module, scheme, compositeID)]` keyed on `"\(module.id)|\(scheme.name)"` so two same-named schemes from different modules don't collide on SwiftUI identity.

## Iteration 7 — xcconfig parsing
- New package leaf: `XcconfigParser.swift` (~110 LOC) — handles simple assignments, trailing `//` comments, relative + optional `#include` / `#include?`, cycle detection.
- Adapter integration: `XcodeProjectAdapter.collectTargets(...)` now merges xcconfig settings at both project and target scope via `baseConfiguration` resolution, then falls back into pbxproj's `buildSettings` dict. Bundle id, deployment target, and platforms now actually populate on cmux (was blank because those live in `.xcconfig`).
- Targets pane: `detailGrid` now always shows Product / Platforms / Deploy min / Bundle ID, falling back to `—` when truly absent. No more silent omission.

## Iteration 8 — chrome polish + load-warnings surface
- Chrome load-error pill: when `loadState` is `.loaded` and `lastLoadError != nil` (i.e. successful reload preserved previous model but had warnings), shows a dismissible orange pill above the tab strip.
- Schemes detail polish: header now has the scheme name + inline shared/personal badge instead of a separate "Visibility" row below.
- Targets detail polish: target detail header now has the product-type SF Symbol at 18pt in accent color + name + product type subtitle, instead of a single `Label`.

## Iteration 9 — test coverage
- New `XcconfigParserTests` suite (6 tests, all green): simple assignments, trailing line comments, relative `#include`, optional `#include?` for missing file, multi-file `parseChain` ordering, cycle detection.
- New adapter tests: `bundleIdentifierIsEitherResolvedOrExplicitlyNilNotFabricated` (guards against `$(...)` leakage), `unresolvableSchemeTargetsReturnNilNotFabricatedID` (guards against T4 regression), `loadReportsAtLeastOneBuildConfigurationPerKnownTarget`.
- 15/15 tests green in 58ms total. Adapter and xcconfig parser have behavior-level coverage that catches the silent-wrong-data bugs flagged in iter1–iter5.

## Iteration 10 — final
- All builds green; test suite 15/15 green; all four tabs render against `cmux.xcodeproj` end-to-end.

## Open backlog (deferred, not in this run)
- `xcodebuild -showBuildSettings -json` integration to produce a true Resolved column (currently uses local effective-or-fallback heuristic).
- Per-module load-warning aggregation across workspace projects (currently uses `try?` in `loadWorkspace`, swallowing per-module errors silently).
- Edit affordances: target membership toggle, settings edit, scheme env edit (all wired through the data model but no write-back yet).
- File watcher / reactive sync via `DispatchSource.makeFileSystemObjectSource` (currently manual reload).
- Fixture-driven adapter tests (currently tests run against the live cmux project; brittle to project shape changes).
