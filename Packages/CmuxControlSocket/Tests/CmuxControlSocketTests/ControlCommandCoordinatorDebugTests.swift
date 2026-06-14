import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugControlCommandContext: ControlCommandContext {
    var guiModeWorkspaceID: UUID?

    func controlDebugOpenGuiModeWorkspace() -> UUID? {
        guiModeWorkspaceID
    }

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
@Suite("ControlCommandCoordinator debug domain")
struct ControlCommandCoordinatorDebugTests {
    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func debugGuiModeOpenReturnsWorkspaceID() {
        let context = FakeDebugControlCommandContext()
        let workspaceID = UUID()
        context.guiModeWorkspaceID = workspaceID

        let coordinator = ControlCommandCoordinator(context: context)

        #expect(coordinator.handle(request("debug.gui_mode.open")) == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
        ])))
    }

    @Test func debugGuiModeOpenReportsUnavailableWithoutTabManager() {
        let coordinator = ControlCommandCoordinator(context: FakeDebugControlCommandContext())

        #expect(coordinator.handle(request("debug.gui_mode.open")) == .err(
            code: "unavailable",
            message: "TabManager not available",
            data: nil
        ))
    }
}
#endif
