# Swift Package Boundaries

Flag Swift changes that keep independently testable feature logic inside the app target when it should be isolated behind a SwiftPM package boundary.

Report a failure when the diff introduces or materially expands:

- A feature implemented directly in the app target/module's root `Sources/` path when its core logic is independent of cmux app lifecycle and can compile/test without AppKit, SwiftUI view state, Ghostty globals, or process-wide singletons.
- Reusable domain logic used by more than one surface (Mac app, CLI, daemon, tests, previews, debug tooling, future iOS/shared code) without a small SwiftPM package target.
- Provider, auth, protocol, parsing, persistence, logging, or workstream logic that needs isolated fakes, fixtures, or unit tests but is hidden behind app-target globals.

Package-boundary signals:

- The code has a stable domain noun and public API that can be expressed without view types.
- The code needs tests that should run without launching cmux or constructing app UI.
- The code owns data formats, network/provider contracts, socket messages, credentials, persistence schemas, or cross-surface state transitions.
- The feature would be safer if callers depended on a small protocol or value API instead of a concrete app singleton.

Allowed cases:

- Small UI-only views, AppKit bridges, app delegates, menu wiring, and Ghostty integration glue that are inherently app-target code.
- Generated files, vendored code, prototypes, and test fixtures.
- New package creation that starts small and intentionally leaves app-specific UI composition in the app target/module-root `Sources/` directory.

When reporting, include the feature boundary and the smallest extraction cut. Name the proposed package target and the first public type or protocol it should expose.
