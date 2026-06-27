import Foundation
import CmuxSettings
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator workspace domain")
struct ControlCommandCoordinatorWorkspaceTests {
    private func coordinator() -> (ControlCommandCoordinator, FakeWorkspaceControlCommandContext) {
        let context = FakeWorkspaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func summary(id: UUID = UUID(), title: String, customTitle: String?) -> ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: id,
            title: title,
            customTitle: customTitle,
            customDescription: nil,
            isPinned: false,
            listeningPorts: [],
            remoteStatus: .object([:]),
            currentDirectory: nil,
            defaultWorkingDirectory: nil,
            customColor: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil
        )
    }

    @Test func workspaceListExposesCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.listResolution = .resolved(
            windowID: nil,
            workspaces: [summary(id: workspaceID, title: "Manual name", customTitle: "Manual name")],
            selectedIndex: 0
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.list")),
              case .array(let rows) = payload["workspaces"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected workspace.list shape")
            return
        }

        #expect(row["id"] == .string(workspaceID.uuidString))
        #expect(row["title"] == .string("Manual name"))
        #expect(row["custom_title"] == .string("Manual name"))
        #expect(row["has_custom_title"] == .bool(true))
    }

    @Test func workspaceListExposesDefaultCwd() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.listResolution = .resolved(
            windowID: nil,
            workspaces: [
                ControlWorkspaceSummary(
                    id: workspaceID,
                    title: "coding",
                    customTitle: "coding",
                    customDescription: nil,
                    isPinned: true,
                    listeningPorts: [],
                    remoteStatus: .object([:]),
                    currentDirectory: "/tmp/live",
                    defaultWorkingDirectory: "/tmp/project",
                    customColor: nil,
                    latestConversationMessage: nil,
                    latestSubmittedMessage: nil,
                    latestSubmittedAt: nil
                ),
            ],
            selectedIndex: 0
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.list")),
              case .array(let rows) = payload["workspaces"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected workspace.list shape")
            return
        }

        #expect(row["current_directory"] == .string("/tmp/live"))
        #expect(row["default_cwd"] == .string("/tmp/project"))
    }

    @Test func workspaceCurrentExposesMissingCustomTitleState() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.currentResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            index: 0,
            summary: summary(id: workspaceID, title: "Terminal", customTitle: nil)
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.current")),
              case .object(let workspace) = payload["workspace"] else {
            Issue.record("unexpected workspace.current shape")
            return
        }

        #expect(workspace["title"] == .string("Terminal"))
        #expect(workspace["custom_title"] == .null)
        #expect(workspace["has_custom_title"] == .bool(false))
    }

    @Test func workspaceGetCwdForwardsExplicitWorkspaceAndReturnsCwd() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.getDefaultDirectoryResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            cwd: "/tmp/project"
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.get_cwd", [
            "workspace_id": .string(workspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.get_cwd result")
            return
        }

        #expect(context.getDefaultDirectoryCall?.workspaceID == workspaceID)
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["workspace_ref"] == .string("workspace:1"))
        #expect(payload["cwd"] == .string("/tmp/project"))
    }

    @Test func workspaceGetCwdRejectsInvalidExplicitWorkspace() throws {
        let (coordinator, context) = coordinator()

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.get_cwd", [
            "workspace_id": .string("not-a-workspace"),
        ])) else {
            Issue.record("unexpected workspace.get_cwd result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Missing or invalid workspace_id")
        #expect(context.getDefaultDirectoryCall == nil)
    }

    @Test func workspaceGetCwdUnavailableUsesGenericWorkspaceMessage() throws {
        let (coordinator, context) = coordinator()
        context.getDefaultDirectoryResolution = .tabManagerUnavailable

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.get_cwd")) else {
            Issue.record("unexpected workspace.get_cwd result")
            return
        }

        #expect(code == "unavailable")
        #expect(message == "Workspace unavailable")
        #expect(context.getDefaultDirectoryCall != nil)
    }

    @Test func workspaceSetCwdAcceptsCwdAndReturnsResolvedCwd() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.setDefaultDirectoryResolution = .resolved(
            windowID: nil,
            workspaceID: workspaceID,
            cwd: "/tmp/project"
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.set_cwd", [
            "workspace_id": .string(workspaceID.uuidString),
            "cwd": .string("  /tmp/project  "),
        ])) else {
            Issue.record("unexpected workspace.set_cwd result")
            return
        }

        #expect(context.setDefaultDirectoryCall?.workspaceID == workspaceID)
        #expect(context.setDefaultDirectoryCall?.cwd == "/tmp/project")
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["cwd"] == .string("/tmp/project"))
    }

    @Test func workspaceSetCwdRejectsInvalidExplicitWorkspace() throws {
        let (coordinator, context) = coordinator()

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.set_cwd", [
            "workspace_id": .string("not-a-workspace"),
            "cwd": .string("/tmp/project"),
        ])) else {
            Issue.record("unexpected workspace.set_cwd result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Missing or invalid workspace_id")
        #expect(context.setDefaultDirectoryCall == nil)
    }

    @Test func workspaceSetCwdRequiresCwd() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.set_cwd", [
            "workspace_id": .string(workspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.set_cwd result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Missing cwd")
        #expect(context.setDefaultDirectoryCall == nil)
    }

    @Test func workspaceSetCwdRejectsPathAlias() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.set_cwd", [
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/tmp/project"),
        ])) else {
            Issue.record("unexpected workspace.set_cwd result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Missing cwd")
        #expect(context.setDefaultDirectoryCall == nil)
    }

    @Test func workspaceGroupAddForwardsPlacementAndReference() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        let referenceWorkspaceID = UUID()
        context.addWorkspaceToGroupResolution = .added

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("after-current"),
            "reference_workspace_id": .string(referenceWorkspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(payload["group_id"] == .string(groupID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(context.addWorkspaceToGroupCall?.groupID == groupID)
        #expect(context.addWorkspaceToGroupCall?.workspaceID == workspaceID)
        #expect(context.addWorkspaceToGroupCall?.placement == .afterCurrent)
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == referenceWorkspaceID)
    }

    @Test func workspaceGroupAddAcceptsNullReferenceWorkspaceID() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        context.addWorkspaceToGroupResolution = .added

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("top"),
            "reference_workspace_id": .null,
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(payload["group_id"] == .string(groupID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(context.addWorkspaceToGroupCall?.groupID == groupID)
        #expect(context.addWorkspaceToGroupCall?.workspaceID == workspaceID)
        #expect(context.addWorkspaceToGroupCall?.placement == .top)
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == nil)
    }

    @Test func workspaceGroupAddRejectsReferenceOutsideTargetGroup() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        let referenceWorkspaceID = UUID()
        context.addWorkspaceToGroupResolution = .invalidReferenceWorkspace

        guard case .err(let code, let message, let data) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("afterCurrent"),
            "reference_workspace_id": .string(referenceWorkspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "invalid reference workspace")
        #expect(data == .object(["reference_workspace_id": .string(referenceWorkspaceID.uuidString)]))
        #expect(context.addWorkspaceToGroupCall?.referenceWorkspaceID == referenceWorkspaceID)
    }

    @Test func workspaceGroupAddRejectsInvalidPlacement() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()

        guard case .err(let code, let message, _) = coordinator.handle(request("workspace.group.add", [
            "group_id": .string(groupID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "placement": .string("middle"),
        ])) else {
            Issue.record("unexpected workspace.group.add result")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "Invalid placement")
        #expect(context.addWorkspaceToGroupCall == nil)
    }
}
