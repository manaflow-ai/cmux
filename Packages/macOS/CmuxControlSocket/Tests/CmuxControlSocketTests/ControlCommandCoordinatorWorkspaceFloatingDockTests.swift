import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeWorkspaceFloatingDockControlContext: ControlCommandContext {
    var resolution: ControlWorkspaceFloatingDockResolution = .resolved(.object(["ok": .bool(true)]))
    var lastWorkspaceID: UUID?
    var lastAction: ControlWorkspaceFloatingDockAction?

    func controlWorkspaceFloatingDock(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        action: ControlWorkspaceFloatingDockAction
    ) -> ControlWorkspaceFloatingDockResolution {
        lastWorkspaceID = workspaceID
        lastAction = action
        return resolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator workspace floating Dock domain")
struct ControlCommandCoordinatorWorkspaceFloatingDockTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeWorkspaceFloatingDockControlContext) {
        let context = FakeWorkspaceFloatingDockControlContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func createParsesOptionalFrameAndPreservesFocusByDefault() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request("workspace.float.create", [
            "title": .string("Scratch"),
            "x": .int(12),
            "y": .int(24),
            "width": .int(640),
            "height": .int(480),
        ]))

        #expect(result == .ok(.object(["ok": .bool(true)])))
        guard case .create(let title, let frame, let focus) = context.lastAction else {
            Issue.record("Expected create action")
            return
        }
        #expect(title == "Scratch")
        #expect(frame == .init(x: 12, y: 24, width: 640, height: 480))
        #expect(focus == false)
    }

    @Test func createRejectsPartialFrameBeforeMutation() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request("workspace.float.create", ["width": .int(500)]))

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid params")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastAction == nil)
    }

    @Test func paneCreateForwardsTopologyInputs() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        _ = coordinator.handle(request("workspace.float.pane.create", [
            "workspace_id": .string(workspaceID.uuidString),
            "float": .string("float:2"),
            "surface_id": .string(surfaceID.uuidString),
            "kind": .string("browser"),
            "direction": .string("down"),
            "url": .string("https://cmux.com"),
            "focus": .bool(true),
        ]))

        #expect(context.lastWorkspaceID == workspaceID)
        #expect(context.lastAction == .paneCreate(
            selector: "float:2",
            sourceSurfaceID: surfaceID,
            kind: "browser",
            direction: "down",
            url: "https://cmux.com",
            focus: true
        ))
    }

    @Test func domainErrorsKeepStableWireCodes() {
        let (coordinator, context) = makeCoordinator()
        context.resolution = .floatingDockNotFound
        let result = coordinator.handle(request("workspace.float.note.get", ["float": .string("9")]))

        guard case .err(let code, let message, _) = result else {
            Issue.record("Expected not found")
            return
        }
        #expect(code == "not_found")
        #expect(message == "Floating Dock not found")
    }
}
