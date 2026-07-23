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

    @Test func surfaceCreateRemotePayloadIdentifiesTmuxNewWindow() throws {
        let workspaceID = UUID()
        let (coordinator, context) = coordinator(createResolution: .routedToRemote(
            windowID: nil,
            workspaceID: workspaceID,
            typeRawValue: "terminal"
        ))

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.create",
            params: ["type": .string("terminal")]
        ))
        _ = context

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected routed remote create payload")
            return
        }

        #expect(payload["accepted"] == .bool(true))
        #expect(payload["routed"] == .string("remote-tmux"))
        #expect(payload["remote_tmux_operation"] == .string("new-window"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
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

    @Test func reportGitBranchForwardsRemoteSurfaceMetadata() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let resolvedSurfaceID = UUID()
        context.reportGitResolution = .recorded(surfaceID: resolvedSurfaceID)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.report_git_branch",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "branch": .string("feature/mosh-parity"),
                "status": .string("unknown"),
            ]
        ))

        #expect(context.reportedGit?.workspaceID == workspaceID)
        #expect(context.reportedGit?.requestedSurfaceID == surfaceID)
        #expect(context.reportedGit?.branch == "feature/mosh-parity")
        #expect(context.reportedGit?.isDirty == nil)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected Git report success")
            return
        }
        #expect(payload["surface_id"] == .string(resolvedSurfaceID.uuidString))
        #expect(payload["branch"] == .string("feature/mosh-parity"))
        #expect(payload["is_dirty"] == .null)
        #expect(payload["cleared"] == .bool(false))
    }

    @Test func reportGitBranchRejectsInvalidDirtyStatus() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.report_git_branch",
            params: [
                "workspace_id": .string(UUID().uuidString),
                "branch": .string("main"),
                "status": .string("maybe"),
            ]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "status must be dirty, clean, or unknown",
            data: nil
        ))
        #expect(context.reportedGit == nil)
    }

    @Test func clearGitBranchResolvesWorkspaceScopedTmuxSurface() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let resolvedSurfaceID = UUID()
        context.reportGitResolution = .recorded(surfaceID: resolvedSurfaceID)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.clear_git_branch",
            params: ["workspace_id": .string(workspaceID.uuidString)]
        ))

        #expect(context.clearedGit?.workspaceID == workspaceID)
        #expect(context.clearedGit?.requestedSurfaceID == nil)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected Git clear success")
            return
        }
        #expect(payload["surface_id"] == .string(resolvedSurfaceID.uuidString))
        #expect(payload["branch"] == .null)
        #expect(payload["cleared"] == .bool(true))
    }
}
