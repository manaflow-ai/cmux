# Swift Concurrency Modernization

Flag clear new uses of legacy asynchronous patterns in cmux-owned Swift code when Swift concurrency would be the correct design.

Report a failure when the diff introduces or materially expands:

- `DispatchQueue.global().async`, custom background queues, `DispatchGroup`, or callback pyramids for ordinary async work that can be modeled with `async` functions, `Task`, `TaskGroup`, or actors.
- New Combine usage (`ObservableObject`, `@Published`, publishers, subscribers, cancellables) for app state or async flow when `Observation` and async/await are available.
- Completion-handler APIs in new internal code when the caller and callee are both under cmux control and can use `async throws`.
- Fire-and-forget `Task { ... }` work with meaningful lifecycle that is not stored, cancelled, or tied to a caller-owned operation.

Allowed cases:

- AppKit, SwiftUI, XCTest, OS, or third-party API boundaries that require a callback or main queue hop.
- Minimal `DispatchQueue.main.async` used only to cross into UI isolation from a legacy callback, when a larger migration is outside the diff.
- Existing legacy code that is only moved or touched nearby without making the pattern worse.
- Tests that intentionally exercise a legacy boundary or create a controlled race/interleaving with `DispatchGroup`, `DispatchQueue.global`, semaphores, or sleeps. Do not flag test-only synchronization unless it ships in app/runtime code or makes production code worse.

When reporting, explain the concrete concurrency replacement. Prefer one finding for the highest-risk changed block instead of listing every instance.
