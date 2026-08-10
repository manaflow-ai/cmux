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

        #expect(context.createdChildWorkspaceIDs == [])
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

    @Test func persistentWorkspaceCreationReturnsCanonicalPendingIdentity() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let groupID = UUID()
        let workspaceID = UUID()
        let requestID = UUID()
        context.newWorkspaceResolution = .submittedToBackend(
            requestID: requestID,
            workspaceID: workspaceID
        )

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.new_workspace",
            ["group_id": .string(groupID.uuidString)]
        )) else {
            Issue.record("persistent workspace creation was not accepted")
            return
        }

        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["pending"] == .bool(true))
        #expect(payload["backend_request_id"] == .string(requestID.uuidString))
        #expect(payload["status_method"] == .string("terminal_backend.mutation_status"))
    }

    @Test func rejectedWorkspaceCreationIsNotReportedAsMissingGroup() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)
        context.newWorkspaceResolution = .requestFailed

        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.group.new_workspace",
            ["group_id": .string(UUID().uuidString)]
        )) else {
            Issue.record("rejected workspace creation was reported as success")
            return
        }

        #expect(code == "request_failed")
    }

    private func request(
        _ method: String,
        _ params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
