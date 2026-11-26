# Swift Actor Isolation

Flag Swift 6 MainActor-by-default isolation mistakes that affect correctness, sendability, or compiler diagnostics.

Report a failure when the diff introduces or materially expands:

- Codable, Identifiable, Sendable, or pure value model structs that remain implicitly `@MainActor` when they should be marked `nonisolated`.
- Service protocols with async requirements that are implicitly MainActor-isolated, causing actor implementations to inherit main actor isolation.
- File-scoped `Logger` constants, pure helpers, data formatters, or value-only utilities that should be `nonisolated` to avoid unnecessary main actor coupling.
- Shared mutable reference types marked `Sendable` without actor isolation, MainActor isolation, a lock with a documented reason, or `@unchecked Sendable` with a clear safety explanation.
- UI-bound models or observable stores accessed from background contexts without an explicit MainActor boundary.

Allowed cases:

- SwiftUI view types and UI coordinators that intentionally live on the main actor.
- Actors, which already provide their own isolation.
- Small structs inside a MainActor-only UI type when they are never used from async or background contexts.
- Existing isolation debt that the PR does not introduce or worsen.

Preferred shapes:

```swift
nonisolated struct Model: Codable, Sendable { ... }
nonisolated protocol Service: Sendable { func load() async throws -> Value }
nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "Feature")
```

When reporting, explain what actor would otherwise own the declaration and why the changed declaration should opt in or out explicitly.
