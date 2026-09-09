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

    @Test func createForwardsCallerOwnedIdentity() {
        let context = FakeWorkspaceGroupSafetyContext()
        context.createResolution = .created(ControlWorkspaceGroupSnapshot(
            id: UUID(),
            name: "Ops",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceID: UUID(),
            customColor: nil,
            iconSymbol: nil,
            memberWorkspaceIDs: [],
            externalID: "repo:cmux",
            anchorWorkspaceProvenance: "generated"
        ))
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.create",
            ["idempotency_key": .string(" repo:cmux ")]
        )) else {
            Issue.record("identity-bearing create did not succeed")
            return
        }

        #expect(context.createdExternalID == "repo:cmux")
        #expect(payload["created"] == .bool(true))
    }

    @Test func repeatedCreateResponseMarksExistingGroup() {
        let context = FakeWorkspaceGroupSafetyContext()
        context.createResolution = .existing(ControlWorkspaceGroupSnapshot(
            id: UUID(),
            name: "Ops",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceID: UUID(),
            customColor: nil,
            iconSymbol: nil,
            memberWorkspaceIDs: [],
            externalID: "repo:cmux",
            anchorWorkspaceProvenance: "generated"
        ))
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.create",
            ["external_id": .string("repo:cmux")]
        )) else {
            Issue.record("existing identity response did not succeed")
            return
        }

        #expect(payload["created"] == .bool(false))
    }

    @Test func ungroupForwardsExplicitGeneratedAnchorCleanup() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let groupID = UUID()

        guard case .ok(.object(let payload)) = coordinator.handle(request(
            "workspace.group.ungroup",
            [
                "group_id": .string(groupID.uuidString),
                "remove_generated_anchor": .bool(true),
            ]
        )) else {
            Issue.record("generated-anchor cleanup did not succeed")
            return
        }

        #expect(context.removeGeneratedAnchor)
        #expect(payload["kept_workspace_count"] == .int(2))
    }

    @Test func createRejectsConflictingIdentityAliases() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.group.create",
            [
                "external_id": .string("repo:a"),
                "idempotency_key": .string("repo:b"),
            ]
        )) else {
            Issue.record("conflicting group identities were accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(context.createdExternalID == nil)
    }

    @Test func ungroupRejectsMalformedGeneratedAnchorIntent() {
        let context = FakeWorkspaceGroupSafetyContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .err(let code, _, _) = coordinator.handle(request(
            "workspace.group.ungroup",
            [
                "group_id": .string(UUID().uuidString),
                "remove_generated_anchor": .string("yes"),
            ]
        )) else {
            Issue.record("malformed generated-anchor intent was accepted")
            return
        }

        #expect(code == "invalid_params")
        #expect(!context.removeGeneratedAnchor)
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
