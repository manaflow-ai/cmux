# Swift Test Target Wiring (pbxproj)

A `.swift` test file that is not wired into the Xcode project is silently never compiled or run. Xcode reports "Executed 0 tests" and both CI and bots see a green diff — indistinguishable from a passing red/green regression test until a real user hits the bug (issue #4529 / PR #4536).

Report a failure when the diff:

- Adds a new `.swift` file under `cmuxTests/` or `cmuxUITests/` without a matching `PBXFileReference` and `PBXSourcesBuildPhase` entry for that file in `cmux.xcodeproj/project.pbxproj` in the same diff.
- Adds a new test file under an `ios/` test target without the corresponding `ios/` project `project.pbxproj` wiring.
- Renames or moves a wired test file without updating its `project.pbxproj` references, leaving a dangling reference or an unwired file.

Allowed cases:

- Test files added to an SPM package's `Tests/` directory — SwiftPM compiles those by convention; no pbxproj entry exists or is needed.
- Pure helper/fixture files intentionally excluded from a test target (e.g. `#if DEBUG`-guarded), with a stated reason.

cmux-specific emphasis:

- The CI guard is `./scripts/lint-pbxproj-test-wiring.sh` (the `workflow-guard-tests` job). Flag the missing wiring at review time so it is fixed before the guard fails or a regression test runs as a no-op.
- The fix is to add the file via Xcode (drag into the `cmuxTests` target) or hand-edit the four pbxproj entries, mirroring a wired sibling such as `TabManagerUnitTests.swift`. After editing, `scripts/normalize-pbxproj.py` + `scripts/check-pbxproj.sh` must pass (objectVersion 60).

When reporting, name the unwired test file and the missing `project.pbxproj` entries.
