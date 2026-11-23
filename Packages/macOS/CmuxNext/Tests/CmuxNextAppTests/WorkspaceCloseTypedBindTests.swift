import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Close Workspace is a typed action (plans/cmux-next/zero-latency.md, "Native actions: the budget contract"): its
/// handler returns what the key's turn changed as an `ActionEffect`, and the registry, not the handler, starts the
/// remote half, takes a refused close back and reports it. An untyped bind (`invoke:`) can start a task that waits
/// for the daemon before anything shows, and nothing in its type says so.
///
/// This reads how the app bound the action in its real composition root (`AppActions.bind`), the fact the action
/// budget report counts (`effect_bound`, `untyped_bound`); it runs no close.
@MainActor @Suite(.serialized) struct WorkspaceCloseTypedBindTests {
    @Test(.timeLimit(.minutes(2)))
    func closeWorkspaceReturnsItsEffectToTheRegistry() async throws {
        try await LargeSessionWindowFixture.withController(.large) { _, controller in
            let action = try #require(controller.services.registry.action(for: "closeWorkspace"), "closeWorkspace is not bound")
            #expect(action.effect != nil, "Close Workspace is bound untyped: its handler starts its own remote work")
        }
    }
}
