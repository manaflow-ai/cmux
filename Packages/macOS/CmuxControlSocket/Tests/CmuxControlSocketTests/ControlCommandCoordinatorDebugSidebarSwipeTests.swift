import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugSidebarSwipeControlCommandContext: ControlCommandContext {
    var requestedWorkspaceID: UUID?
    var requestedAction: ControlDebugSidebarSwipeAction?
    var resolution: ControlDebugSidebarSwipeResolution = .simulated(
        committed: false,
        offset: 80,
        released: false
    )

    func controlDebugSimulateSidebarSwipe(
        workspaceID: UUID,
        action: ControlDebugSidebarSwipeAction
    ) -> ControlDebugSidebarSwipeResolution {
        requestedWorkspaceID = workspaceID
        requestedAction = action
        return resolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator debug sidebar swipe dispatch")
struct ControlCommandCoordinatorDebugSidebarSwipeTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeDebugSidebarSwipeControlCommandContext) {
        let context = FakeDebugSidebarSwipeControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "debug.sidebar.simulate_swipe", params: params)
    }

    @Test func simulateSwipeDispatchesToDebugSeam() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()

        let result = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "action": .string("reveal-leading"),
        ]))

        #expect(context.requestedWorkspaceID == workspaceID)
        #expect(context.requestedAction == .revealLeading)
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "action": .string("reveal-leading"),
            "committed": .bool(false),
            "offset": .double(80),
            "released": .bool(false),
        ])))
    }

    @Test func simulateSwipeRequiresWorkspaceID() {
        let (coordinator, _) = makeCoordinator()

        guard case .err(let code, let message, _) = coordinator.handle(request([
            "action": .string("release")
        ])) else {
            Issue.record("expected err")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Missing or invalid workspace_id")
    }

    @Test func simulateSwipeRequiresKnownAction() {
        let (coordinator, _) = makeCoordinator()
        let workspaceID = UUID()

        guard case .err(let code, let message, let data) = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "action": .string("bogus"),
        ])) else {
            Issue.record("expected err")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Missing or invalid action")
        #expect(data == .object([
            "actions": .array([
                .string("reveal-leading"),
                .string("reveal-trailing"),
                .string("commit-leading"),
                .string("commit-trailing"),
                .string("release"),
            ])
        ]))
    }

    @Test func simulateSwipeReturnsNotFoundWhenRowIsNotRegistered() {
        let (coordinator, context) = makeCoordinator()
        context.resolution = .rowNotRegistered
        let workspaceID = UUID()

        guard case .err(let code, let message, let data) = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "action": .string("release"),
        ])) else {
            Issue.record("expected err")
            return
        }

        #expect(code == "not_found")
        #expect(message == "Sidebar row is not registered")
        #expect(data == .object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
        ]))
    }
}
#endif
