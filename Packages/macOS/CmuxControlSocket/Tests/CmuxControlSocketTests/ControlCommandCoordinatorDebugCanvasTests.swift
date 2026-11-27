import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
@Suite("ControlCommandCoordinator debug canvas dispatch")
struct ControlCommandCoordinatorDebugCanvasTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeDebugCanvasControlCommandContext) {
        let context = FakeDebugCanvasControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func showCanvasCommandScrollHintPassesRoutingThroughDebugSeam() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()

        let result = coordinator.handle(request(
            "debug.canvas.command_scroll_hint",
            ["workspace_id": .string(workspaceID.uuidString)]
        ))

        #expect(result == .ok(.object(["mode": .string("canvas")])))
        #expect(context.lastRouting?.workspaceID == workspaceID)
    }

    @Test func showCanvasCommandScrollHintMapsMissingViewportToInvalidState() {
        let (coordinator, context) = makeCoordinator()
        context.resolution = .viewportUnavailable

        guard case .err(let code, let message, _) = coordinator.handle(
            request("debug.canvas.command_scroll_hint")
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_state")
        #expect(message == "Canvas viewport is not attached")
    }
}
#endif
