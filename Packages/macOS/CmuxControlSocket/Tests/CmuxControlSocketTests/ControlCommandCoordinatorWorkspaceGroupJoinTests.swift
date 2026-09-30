import Foundation
import CmuxSettings
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator workspace-group join")
struct ControlCommandCoordinatorWorkspaceGroupJoinTests {
    private func coordinator() -> (ControlCommandCoordinator, FakeWorkspaceControlCommandContext) {
        let context = FakeWorkspaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func workspaceGroupJoinTrimsNameAndReportsCreation() throws {
        let (coordinator, context) = coordinator()
        let groupID = UUID()
        let workspaceID = UUID()
        context.joinWorkspaceGroupResolution = .joined(
            ControlWorkspaceGroupSnapshot(
                id: groupID,
                name: "Sidebar",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceID: UUID(),
                customColor: nil,
                iconSymbol: nil,
                memberWorkspaceIDs: [workspaceID]
            ),
            created: true,
            alreadyMember: false
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.join", [
            "name": .string("  Sidebar \n"),
            "workspace_id": .string(workspaceID.uuidString),
        ])),
              case .object(let group) = payload["group"] else {
            Issue.record("unexpected workspace.group.join result")
            return
        }

        #expect(context.joinWorkspaceGroupCall?.name == "Sidebar")
        #expect(context.joinWorkspaceGroupCall?.workspaceID == workspaceID)
        #expect(group["id"] == .string(groupID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["created"] == .bool(true))
        #expect(payload["already_member"] == .bool(false))
    }

    @Test func workspaceGroupJoinReportsAnExistingMembership() throws {
        let (coordinator, context) = coordinator()
        let workspaceID = UUID()
        context.joinWorkspaceGroupResolution = .joined(
            ControlWorkspaceGroupSnapshot(
                id: UUID(),
                name: "Release",
                isCollapsed: false,
                isPinned: false,
                anchorWorkspaceID: UUID(),
                customColor: nil,
                iconSymbol: nil,
                memberWorkspaceIDs: [workspaceID]
            ),
            created: false,
            alreadyMember: true
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request("workspace.group.join", [
            "name": .string("release"),
            "workspace_id": .string(workspaceID.uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.join result")
            return
        }

        #expect(payload["created"] == .bool(false))
        #expect(payload["already_member"] == .bool(true))
        #expect(payload["workspace_ref"] != nil)
    }

    @Test func workspaceGroupJoinRejectsBlankName() throws {
        let (coordinator, context) = coordinator()

        guard case .err(let code, _, _) = coordinator.handle(request("workspace.group.join", [
            "name": .string("   "),
            "workspace_id": .string(UUID().uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.join result")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.joinWorkspaceGroupCall == nil)
    }

    @Test func workspaceGroupJoinReportsOtherGroupAnchor() throws {
        let (coordinator, context) = coordinator()
        context.joinWorkspaceGroupResolution = .workspaceIsOtherGroupAnchor

        guard case .err(let code, _, _) = coordinator.handle(request("workspace.group.join", [
            "name": .string("Sidebar"),
            "workspace_id": .string(UUID().uuidString),
        ])) else {
            Issue.record("unexpected workspace.group.join result")
            return
        }

        #expect(code == "invalid_state")
    }
}
