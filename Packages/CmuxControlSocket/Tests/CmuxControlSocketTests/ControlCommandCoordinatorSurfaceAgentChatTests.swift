import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving `surface.agent_chat.open`
/// without the app target. Every other domain seam comes from the benign stub
/// defaults in `ControlCommandContextTestStubs.swift`.
@MainActor
private final class FakeAgentChatContext: ControlCommandContext {
    var routingResolvesTabManager = false
    var agentChatResolution: ControlSurfaceAgentChatOpenResolution = .tabManagerUnavailable
    var lastRouting: ControlRoutingSelectors?
    var lastSurfaceID: UUID?
    var openCallCount = 0

    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        routingResolvesTabManager
    }

    func controlSurfaceAgentChatOpen(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceAgentChatOpenResolution {
        openCallCount += 1
        lastRouting = routing
        lastSurfaceID = surfaceID
        return agentChatResolution
    }

    // Inert window-domain members: the stubs file deliberately carries no
    // defaults for the window domain, and this fake never exercises it.
    func controlWindowSummaries() -> [ControlWindowSummary] { [] }
    func controlResolveCurrentWindow(routing: ControlRoutingSelectors) -> ControlCurrentWindowResolution {
        .tabManagerUnavailable
    }
    func controlFocusWindow(id: UUID) -> Bool { false }
    func controlCreateWindowAndActivate() -> UUID? { nil }
    func controlCloseWindow(id: UUID) -> Bool { false }
    func controlAvailableDisplays() -> [ControlDisplayInfo] { [] }
    func controlWindowExists(id: UUID) -> Bool { false }
    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? { nil }
    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? { nil }
}

@MainActor
@Suite("ControlCommandCoordinator surface.agent_chat.open")
struct ControlCommandCoordinatorSurfaceAgentChatTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeAgentChatContext) {
        let context = FakeAgentChatContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "surface.agent_chat.open", params: params)
    }

    /// The verb is registered in the surface domain (the coordinator must not
    /// fall through to the legacy app-side dispatcher).
    @Test func verbIsDispatchedBySurfaceDomain() {
        let (coordinator, _) = makeCoordinator()
        let result = coordinator.handle(request())
        #expect(result != nil)
    }

    /// The verb runs on the main actor lane like every other surface verb.
    @Test func verbRunsOnMainActor() {
        #expect(ControlCommandExecutionPolicy(forMethod: "surface.agent_chat.open") == .mainActor)
    }

    @Test func unresolvedTabManagerIsUnavailable() {
        let (coordinator, context) = makeCoordinator()
        context.routingResolvesTabManager = false
        guard case .err(let code, _, _)? = coordinator.handle(request()) else {
            Issue.record("Expected an error result")
            return
        }
        #expect(code == "unavailable")
        #expect(context.openCallCount == 0)
    }

    @Test func explicitSurfaceIDReachesTheContextSeam() {
        let (coordinator, context) = makeCoordinator()
        context.routingResolvesTabManager = true
        let workspaceID = UUID()
        let surfaceID = UUID()
        context.agentChatResolution = .requested(
            windowID: nil,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        let result = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "surface_id": .string(surfaceID.uuidString),
        ]))
        guard case .ok(.object(let payload))? = result else {
            Issue.record("Expected ok result, got \(String(describing: result))")
            return
        }
        #expect(context.openCallCount == 1)
        #expect(context.lastSurfaceID == surfaceID)
        #expect(context.lastRouting?.workspaceID == workspaceID)
        #expect(payload["requested"] == .bool(true))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
    }

    @Test func missingSurfaceMapsToNotFound() {
        let (coordinator, context) = makeCoordinator()
        context.routingResolvesTabManager = true
        let missing = UUID()
        context.agentChatResolution = .surfaceNotFound(missing)
        guard case .err(let code, let message, let data)? = coordinator.handle(request()) else {
            Issue.record("Expected an error result")
            return
        }
        #expect(code == "not_found")
        #expect(message == "Surface not found")
        #expect(data == .object(["surface_id": .string(missing.uuidString)]))
    }

    @Test func noFocusedSurfaceMapsToNotFound() {
        let (coordinator, context) = makeCoordinator()
        context.routingResolvesTabManager = true
        context.agentChatResolution = .noFocusedSurface
        guard case .err(let code, let message, _)? = coordinator.handle(request()) else {
            Issue.record("Expected an error result")
            return
        }
        #expect(code == "not_found")
        #expect(message == "No focused surface")
    }
}

extension ControlCommandCoordinatorSurfaceAgentChatTests {
    /// A present-but-malformed explicit selector must fail instead of silently
    /// falling back to the current window/workspace/focused surface
    /// (wrong-target open with success). Same rule as the resume verbs.
    @Test(arguments: ["window_id", "workspace_id", "surface_id", "tab_id"])
    func malformedExplicitSelectorIsInvalidParams(key: String) {
        let (coordinator, context) = makeCoordinator()
        context.routingResolvesTabManager = true
        guard case .err(let code, let message, _)? = coordinator.handle(
            request([key: .string("not-a-uuid")])
        ) else {
            Issue.record("Expected an error result for \(key)")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == "Missing or invalid \(key)")
        #expect(context.openCallCount == 0)
    }
}
