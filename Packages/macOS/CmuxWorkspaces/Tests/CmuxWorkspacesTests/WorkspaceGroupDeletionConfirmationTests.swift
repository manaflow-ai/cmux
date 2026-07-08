import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
struct WorkspaceGroupDeletionConfirmationTests {
    private func makeWorld() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        groups: WorkspaceGroupCoordinator<CoordinatorStubTab>
    ) {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        return (model, host, groups)
    }

    @Test
    func confirmationUsesLiveMembershipAfterAllMembersAreDetached() throws {
        let (model, host, groups) = makeWorld()
        _ = host
        let first = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        model.tabs = [first, second]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [first.id, second.id]))
        let staleMemberCount = model.tabs.filter { $0.groupId == groupId }.count
        #expect(staleMemberCount > 1)

        let memberIds = model.tabs.compactMap { $0.groupId == groupId ? $0.id : nil }
        for id in memberIds {
            model.assignGroup(workspaceId: id, groupId: nil)
        }

        let confirmation = try #require(groups.deletionConfirmation(groupId: groupId))
        #expect(confirmation.groupId == groupId)
        #expect(confirmation.groupName == "G")
        #expect(confirmation.memberWorkspaceIds.isEmpty)
        #expect(confirmation.memberCount == 0)

        let closed = groups.deleteWorkspaceGroup(groupId: groupId)

        #expect(closed == 0)
        #expect(!model.workspaceGroups.contains { $0.id == groupId })
    }

    @Test
    func confirmationDisappearsAfterRealUngroup() throws {
        let (model, host, groups) = makeWorld()
        _ = host
        let first = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        model.tabs = [first, second]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [first.id, second.id]))
        #expect(groups.deletionConfirmation(groupId: groupId)?.memberCount ?? 0 > 1)

        groups.ungroupWorkspaceGroup(groupId: groupId)

        #expect(groups.deletionConfirmation(groupId: groupId) == nil)
        #expect(!model.workspaceGroups.contains { $0.id == groupId })
    }
}
