# Swift File And Package Boundaries

Flag Swift changes that add too much unrelated responsibility to one file or keep independently testable feature logic inside the app target when it should be isolated behind a SwiftPM package boundary.

cmux already has a checked-in Swift file length budget reference (`.github/swift-file-length-budget.tsv` and `scripts/swift_file_length_budget.py`). This rule is the enforcement layer for review: do not satisfy it by mechanically moving code around, and do not expand the TSV budget for a feature that should instead be split by responsibility or extracted into a package.

Report a failure when the diff introduces or materially expands:

- A new production Swift file over 400 lines without a clear single responsibility, or over 800 lines even when the responsibility is mostly coherent.
- More than 250 lines added to an existing production Swift file that is already over 800 lines. Treat an extraction exception as met only when the PR removes or moves one of the mixed responsibilities listed below out of the file, or documents that responsibility behind a new package boundary, and the file's total line count decreases by more than 200 lines. A new SwiftPM package target can satisfy this exception when the oversized file also shrinks by more than 200 lines because code moved into that target.
- A file that mixes UI rendering, state ownership, persistence, networking, parsing, subprocess/socket protocol, and platform bridge code in one place.
- A feature implemented directly in the app target/module's root `Sources/` path when its core logic is independent of cmux app lifecycle and can compile/test without AppKit, SwiftUI view state, Ghostty globals, or process-wide singletons.
- Reusable domain logic used by more than one surface (Mac app, CLI, daemon, tests, previews, debug tooling, future iOS/shared code) without a small SwiftPM package target.
- Provider, auth, protocol, parsing, persistence, logging, or workstream logic that needs isolated fakes, fixtures, or unit tests but is hidden behind app-target globals.
- A PR that primarily updates `.github/swift-file-length-budget.tsv` to accept growth instead of reducing the large file, splitting responsibilities, or adding a package boundary.

Line counting follows the existing budget script as a shared measurement convention, even if that script is not required as an active CI gate: count physical lines including blank lines; scan cmux-owned Swift files under `Sources`, `CLI`, `Packages`, `cmuxTests`, and `cmuxUITests`; exclude whole path subtrees containing `/vendor/`, `/ghostty/`, `/homebrew-cmux/`, `/SourcePackages/`, or `/.ci-source-packages/`; and use 500 lines as the tracked-file reference threshold from `.github/swift-file-length-budget.tsv`. For this LLM rule, use the post-change physical file length when visible; use PR added-line count only for the "more than 250 lines added" growth check.

Package-boundary signals:

- The code has a stable domain noun and public API that can be expressed without view types.
- The code needs tests that should run without launching cmux or constructing app UI.
- The code owns data formats, network/provider contracts, socket messages, credentials, persistence schemas, or cross-surface state transitions.
- The feature would be safer if callers depended on a small protocol or value API instead of a concrete app singleton.

Allowed cases:

- Existing oversized files that the PR only touches incidentally.
- Small UI-only views, AppKit bridges, app delegates, menu wiring, and Ghostty integration glue that are inherently app-target code.
- Focused bug fixes that add a small amount of code to a large file while preserving a clear extraction path.
- Generated files, vendored code, prototypes, and test fixtures.
- New package creation that starts small and intentionally leaves app-specific UI composition in the app target/module-root `Sources/` directory.

When reporting, include the file or feature boundary, the approximate line-count pressure, the responsibilities being mixed, and the smallest extraction cut. If a package is the right shape, name the proposed package target and the first public type or protocol it should expose.
