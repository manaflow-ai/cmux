import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("Control command workspace-group safety")
struct ControlCommandCoordinatorWorkspaceGroupSafetyTests {
    @Test func bareCreateUsesAnExplicitEmptyMemberList() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(request("workspace.group.create"))

        #expect(context.createCall?.childWorkspaceIDs == [])
    }

    @Test func deleteDefaultsToDissolvingTheGroup() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let groupID = UUID()

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.delete",
            ["group_id": .string(groupID.uuidString)]
        )) else {
            Issue.record("workspace.group.delete did not succeed")
            return
        }

        #expect(context.ungroupedGroupIDs == [groupID])
        #expect(context.deletedGroupIDs.isEmpty)
        #expect(payload["operation"] == .string("dissolved"))
        #expect(payload["kept_workspace_count"] == .int(2))
    }

    @Test func deleteClosesWorkspacesOnlyWithExplicitIntent() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let groupID = UUID()

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.delete",
            [
                "group_id": .string(groupID.uuidString),
                "close_workspaces": .bool(true),
            ]
        )) else {
            Issue.record("explicit destructive workspace.group.delete did not succeed")
            return
        }

        #expect(context.ungroupedGroupIDs.isEmpty)
        #expect(context.deletedGroupIDs == [groupID])
        #expect(payload["operation"] == .string("closed_workspaces"))
        #expect(payload["closed_workspace_count"] == .int(2))
    }

    @Test func deleteRejectsMalformedDestructiveIntentWithoutMutating() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let groupID = UUID()

        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.group.delete",
            [
                "group_id": .string(groupID.uuidString),
                "close_workspaces": .string("sometimes"),
            ]
        )) else {
            Issue.record("malformed destructive intent was accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.ungroupedGroupIDs.isEmpty)
        #expect(context.deletedGroupIDs.isEmpty)
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
