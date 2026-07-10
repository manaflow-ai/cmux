import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator surface domain")
struct ControlCommandCoordinatorSurfaceTests {
    private func coordinator(
        createResolution: ControlSurfaceCreateResolution
    ) -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        context.createResolution = createResolution
        return (ControlCommandCoordinator(context: context), context)
    }

    @Test func surfaceCreateDockPayloadUsesDockScopedIDs() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let dockPaneID = UUID()
        let dockSurfaceID = UUID()
        let (coordinator, context) = coordinator(createResolution: .createdDock(
            windowID: windowID,
            workspaceID: workspaceID,
            dockPaneID: dockPaneID,
            dockSurfaceID: dockSurfaceID,
            typeRawValue: "browser"
        ))

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.create",
            params: [
                "type": .string("browser"),
                "placement": .string("dock"),
            ]
        ))
        _ = context

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected dock create payload")
            return
        }

        #expect(payload["placement"] == .string("dock"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["surface_id"] == .null)
        #expect(payload["surface_ref"] == .null)
        #expect(payload["pane_id"] == .null)
        #expect(payload["pane_ref"] == .null)
        #expect(payload["dock_surface_id"] == .string(dockSurfaceID.uuidString))
        #expect(payload["dock_pane_id"] == .string(dockPaneID.uuidString))
        #expect(payload["type"] == .string("browser"))
    }

    @Test func paneCreateDockPayloadUsesDockScopedIDs() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let dockPaneID = UUID()
        let dockSurfaceID = UUID()
        let context = FakeSurfaceControlCommandContext()
        context.paneCreateResolution = .createdDock(
            windowID: windowID,
            workspaceID: workspaceID,
            dockPaneID: dockPaneID,
            dockSurfaceID: dockSurfaceID,
            typeRawValue: "terminal"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "placement": .string("dock"),
            ]
        ))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected dock pane create payload")
            return
        }

        #expect(payload["placement"] == .string("dock"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["surface_id"] == .null)
        #expect(payload["surface_ref"] == .null)
        #expect(payload["pane_id"] == .null)
        #expect(payload["pane_ref"] == .null)
        #expect(payload["dock_surface_id"] == .string(dockSurfaceID.uuidString))
        #expect(payload["dock_pane_id"] == .string(dockPaneID.uuidString))
        #expect(payload["type"] == .string("terminal"))
    }

    @Test func surfaceCreateDockUnsupportedTypeReturnsInvalidParams() throws {
        let (coordinator, context) = coordinator(createResolution: .dockUnsupportedType(
            typeRawValue: "agentSession",
            message: "Dock placement supports only terminal and browser surfaces"
        ))
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.create",
            params: [
                "type": .string("agent-session"),
                "placement": .string("dock"),
            ]
        ))
        _ = context

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected invalid_params error")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Dock placement supports only terminal and browser surfaces")
        #expect(data == .object(["type": .string("agentSession")]))
    }

    @Test func paneCreateDockUnsupportedTypeReturnsInvalidParams() throws {
        let context = FakeSurfaceControlCommandContext()
        context.paneCreateResolution = .dockUnsupportedType(
            typeRawValue: "markdown",
            message: "Dock placement supports only terminal and browser surfaces"
        )
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "type": .string("markdown"),
                "placement": .string("dock"),
            ]
        ))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected invalid_params error")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Dock placement supports only terminal and browser surfaces")
        #expect(data == .object(["type": .string("markdown")]))
    }

    @Test func surfacePipPopReturnsResultingState() throws {
        let surfaceID = UUID()
        let context = FakeSurfaceControlCommandContext()
        context.pipResolution = .changed(surfaceID: surfaceID, isInPictureInPicture: true)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.pip",
            params: [
                "surface_id": .string(surfaceID.uuidString),
                "action": .string("pop"),
            ]
        ))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected surface.pip success payload")
            return
        }
        #expect(context.pipRequest?.surfaceID == surfaceID)
        #expect(context.pipRequest?.actionRawValue == "pop")
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
        #expect(payload["in_picture_in_picture"] == .bool(true))
        #expect(payload["action"] == .string("pop"))
    }

    @Test func surfacePipForwardsWindowRoutingSelector() throws {
        let surfaceID = UUID()
        let windowID = UUID()
        let context = FakeSurfaceControlCommandContext()
        context.pipResolution = .changed(surfaceID: surfaceID, isInPictureInPicture: true)
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.pip",
            params: [
                "window_id": .string(windowID.uuidString),
                "action": .string("pop"),
            ]
        ))

        #expect(context.pipRequest?.routing.hasWindowIDParam == true)
        #expect(context.pipRequest?.routing.windowID == windowID)
        #expect(context.pipRequest?.surfaceID == nil)
        #expect(context.pipRequest?.actionRawValue == "pop")
    }

    @Test func surfacePipReturnReturnsResultingState() throws {
        let surfaceID = UUID()
        let context = FakeSurfaceControlCommandContext()
        context.pipResolution = .changed(surfaceID: surfaceID, isInPictureInPicture: false)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.pip",
            params: [
                "surface_id": .string(surfaceID.uuidString),
                "action": .string("return"),
            ]
        ))

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected surface.pip return payload")
            return
        }
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
        #expect(payload["in_picture_in_picture"] == .bool(false))
        #expect(payload["action"] == .string("return"))
    }

    @Test func surfacePipUnsupportedTypeReturnsInvalidParams() throws {
        let surfaceID = UUID()
        let context = FakeSurfaceControlCommandContext()
        context.pipResolution = .unsupportedSurfaceType
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.pip",
            params: [
                "surface_id": .string(surfaceID.uuidString),
                "action": .string("pop"),
            ]
        ))

        guard case .err(let code, let message, _) = result else {
            Issue.record("expected surface.pip invalid_params error")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == "Picture in Picture supports only terminal and browser surfaces")
    }

    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "surface.report_pwd", params: params)
    }

    @Test func reportPWDRejectsConflictingPathAliases() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let result = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar"),
            "cwd": .string("/srv/work/other"),
        ]))

        #expect(result == .err(code: "invalid_params", message: "Conflicting path parameters", data: nil))
        #expect(context.reportedPWD?.path == nil)
    }

    @Test func reportPWDPreservesExactPathWhitespace() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        _ = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar "),
        ]))

        #expect(context.reportedPWD?.path == "/srv/work/bar ")
    }
}
