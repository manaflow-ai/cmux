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
            "kind": .string("browser"),
            "url": .string("https://cmux.com"),
            "color": .string("#272822"),
            "relative_to": .string("float:1"),
            "x": .int(12),
            "y": .int(24),
            "width": .int(640),
            "height": .int(480),
        ]))

        #expect(result == .ok(.object(["ok": .bool(true)])))
        guard case .create(
            let title,
            let frame,
            let kind,
            let url,
            let color,
            let relativeTo,
            let focus
        ) = context.lastAction else {
            Issue.record("Expected create action")
            return
        }
        #expect(title == "Scratch")
        #expect(frame == .init(x: 12, y: 24, width: 640, height: 480))
        #expect(kind == "browser")
        #expect(url == "https://cmux.com")
        #expect(color == "#272822")
        #expect(relativeTo == "float:1")
        #expect(focus == false)
    }

    @Test func createDefaultsToTerminalContent() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(request("workspace.float.create"))

        guard case .create(_, _, let kind, _, _, _, _) = context.lastAction else {
            Issue.record("Expected create action")
            return
        }
        #expect(kind == "terminal")
    }

    @Test func colorSetForwardsPerWindowTint() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(request("workspace.float.color.set", [
            "float": .string("float:2"),
            "color": .string("#272822"),
        ]))

        #expect(context.lastAction == .colorSet(
            selector: "float:2",
            backgroundTintHex: "#272822"
        ))
    }

    @Test func closeAllForwardsOneWorkspaceScopedAction() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(request("workspace.float.close_all"))

        #expect(context.lastAction == .closeAll)
    }

    @Test func stashRestoreAndRestoreAllForwardSharedLifecycleActions() {
        let (coordinator, context) = makeCoordinator()

        _ = coordinator.handle(request("workspace.float.stash", [
            "float": .string("float:2"),
        ]))
        #expect(context.lastAction == .stash(selector: "float:2"))

        _ = coordinator.handle(request("workspace.float.restore", [
            "float": .string("float:2"),
            "focus": .bool(true),
        ]))
        #expect(context.lastAction == .restore(selector: "float:2", focus: true))

        _ = coordinator.handle(request("workspace.float.restore_all"))
        #expect(context.lastAction == .restoreAll(focus: false))
    }

    @Test func renameAndReorderForwardWorkspaceScopedMutations() {
        let (coordinator, context) = makeCoordinator()

        _ = coordinator.handle(request("workspace.float.rename", [
            "float": .string("float:2"),
            "title": .string("Release Notes"),
        ]))
        #expect(context.lastAction == .rename(
            selector: "float:2",
            title: "Release Notes"
        ))

        _ = coordinator.handle(request("workspace.float.reorder", [
            "float": .string("float:2"),
            "position": .int(3),
        ]))
        #expect(context.lastAction == .reorder(
            selector: "float:2",
            position: 3
        ))
    }

    @Test func renameAndReorderRejectInvalidInputsBeforeDispatch() {
        let (coordinator, context) = makeCoordinator()

        let blankTitle = coordinator.handle(request("workspace.float.rename", [
            "float": .string("float:1"),
            "title": .string("   "),
        ]))
        guard case .err(let renameCode, _, _) = blankTitle else {
            Issue.record("Expected invalid rename params")
            return
        }
        #expect(renameCode == "invalid_params")
        #expect(context.lastAction == nil)

        let zeroPosition = coordinator.handle(request("workspace.float.reorder", [
            "float": .string("float:1"),
            "position": .int(0),
        ]))
        guard case .err(let reorderCode, _, _) = zeroPosition else {
            Issue.record("Expected invalid reorder params")
            return
        }
        #expect(reorderCode == "invalid_params")
        #expect(context.lastAction == nil)

        let oversizedCreateTitle = coordinator.handle(request("workspace.float.create", [
            "title": .string(String(repeating: "x", count: 121)),
        ]))
        guard case .err(let createCode, _, _) = oversizedCreateTitle else {
            Issue.record("Expected invalid create title params")
            return
        }
        #expect(createCode == "invalid_params")
        #expect(context.lastAction == nil)
    }

    @Test func closePendingReturnsAcceptedPayload() {
        let (coordinator, context) = makeCoordinator()
        let payload: JSONValue = .object([
            "float_id": .string(UUID().uuidString),
            "status": .string("pending"),
        ])
        context.resolution = .pending(payload)

        let result = coordinator.handle(request("workspace.float.close", [
            "float": .string("float:1"),
        ]))

        #expect(result == .ok(payload))
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

    @Test func createRejectsExtremeFrameBeforeMutation() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request("workspace.float.create", [
            "x": .int(0),
            "y": .int(0),
            "width": .double(Double.greatestFiniteMagnitude),
            "height": .int(480),
        ]))

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

        context.resolution = .invalidParkingPosition(maximum: 2)
        let invalidPosition = coordinator.handle(request("workspace.float.reorder", [
            "float": .string("float:1"),
            "position": .int(3),
        ]))
        guard case .err(let positionCode, _, let data) = invalidPosition else {
            Issue.record("Expected invalid parking position")
            return
        }
        #expect(positionCode == "invalid_params")
        #expect(data == .object(["maximum_position": .int(2)]))
    }

    @Test func malformedWorkspaceSelectorFailsBeforeDispatch() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request("workspace.float.create", [
            "workspace_id": .string("not-a-workspace"),
        ]))

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid params")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastAction == nil)
    }

    @Test func malformedPaneSelectorFailsBeforeSurfaceCreation() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request("workspace.float.surface.create", [
            "float": .string("float:1"),
            "kind": .string("terminal"),
            "pane_id": .string("not-a-pane"),
        ]))

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid params")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastAction == nil)
    }

    @Test func malformedSplitSourceFailsBeforePaneCreation() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request("workspace.float.pane.create", [
            "float": .string("float:1"),
            "kind": .string("terminal"),
            "surface_id": .string("not-a-surface"),
        ]))

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid params")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastAction == nil)
    }

    @Test func internalFailureDetailsStayOffTheWire() {
        let (coordinator, context) = makeCoordinator()
        context.resolution = .operationFailed("private implementation detail")
        let result = coordinator.handle(request("workspace.float.list"))

        guard case .err(let code, let message, _) = result else {
            Issue.record("Expected internal error")
            return
        }
        #expect(code == "internal_error")
        #expect(!message.contains("private implementation detail"))
        #expect(!message.contains("TabManager"))
    }
}
