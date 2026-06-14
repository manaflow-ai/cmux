import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugControlCommandContext: ControlCommandContext {
    var guiModeWorkspaceID: UUID?
    var guiModeSubmitResolution = ControlDebugGuiModeSubmitResolution.unavailable
    var guiModeSubmitPrompt: String?
    var guiModeSubmitProviderID: String?

    func controlDebugOpenGuiModeWorkspace() -> UUID? {
        guiModeWorkspaceID
    }

    func controlDebugSubmitGuiModeTask(
        prompt: String,
        providerID: String?
    ) -> ControlDebugGuiModeSubmitResolution {
        guiModeSubmitPrompt = prompt
        guiModeSubmitProviderID = providerID
        return guiModeSubmitResolution
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

    @Test func debugGuiModeSubmitReturnsWorkspaceID() {
        let context = FakeDebugControlCommandContext()
        let workspaceID = UUID()
        context.guiModeSubmitResolution = .created(workspaceID: workspaceID)

        let coordinator = ControlCommandCoordinator(context: context)

        #expect(coordinator.handle(request("debug.gui_mode.submit", [
            "prompt": .string("build it"),
            "provider_id": .string("claude"),
        ])) == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
        ])))
        #expect(context.guiModeSubmitPrompt == "build it")
        #expect(context.guiModeSubmitProviderID == "claude")
    }

    @Test func debugGuiModeSubmitRequiresPrompt() {
        let coordinator = ControlCommandCoordinator(context: FakeDebugControlCommandContext())

        #expect(coordinator.handle(request("debug.gui_mode.submit")) == .err(
            code: "invalid_params",
            message: "Missing prompt",
            data: nil
        ))
    }

    @Test func debugGuiModeSubmitReportsUnknownProvider() {
        let context = FakeDebugControlCommandContext()
        context.guiModeSubmitResolution = .invalidProvider("unknown")

        let coordinator = ControlCommandCoordinator(context: context)

        #expect(coordinator.handle(request("debug.gui_mode.submit", [
            "prompt": .string("build it"),
            "provider_id": .string("unknown"),
        ])) == .err(
            code: "invalid_params",
            message: "Unknown provider: unknown",
            data: nil
        ))
    }
}
#endif
