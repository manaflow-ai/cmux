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
        let first = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        model.tabs = [first, second]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [first.id, second.id]))
        let group = try #require(model.workspaceGroups.first { $0.id == groupId })
        let anchorId = group.anchorWorkspaceId
        let staleMemberCount = model.tabs.filter { $0.groupId == groupId }.count
        #expect(staleMemberCount > 1)

        let memberIds = model.tabs.compactMap { $0.groupId == groupId ? $0.id : nil }
        for id in memberIds {
            model.assignGroup(workspaceId: id, groupId: nil)
        }

        let confirmation = try #require(groups.deletionConfirmation(groupId: groupId))
        #expect(confirmation.groupId == groupId)
        #expect(confirmation.groupName == "G")
        #expect(confirmation.memberWorkspaceIds == [anchorId])
        #expect(confirmation.memberCount == 1)
        #expect(confirmation.containedWorkspaceCount == 0)

        let closed = groups.deleteWorkspaceGroup(groupId: groupId)

        #expect(closed == 1)
        #expect(host.closedWorkspaceIds == [anchorId])
        #expect(!model.workspaceGroups.contains { $0.id == groupId })
        #expect(host.orderChanges.last == [anchorId])
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

    @Test
    func deleteAfterRemovingAllChildrenSeesEmptyGroupAndClosesHeaderOnly() throws {
        let (model, host, groups) = makeWorld()
        let first = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        model.tabs = [first, second]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [first.id, second.id]))
        let group = try #require(model.workspaceGroups.first { $0.id == groupId })
        let anchorId = group.anchorWorkspaceId

        groups.removeWorkspaceFromGroup(workspaceId: first.id)
        groups.removeWorkspaceFromGroup(workspaceId: second.id)

        let confirmation = try #require(groups.deletionConfirmation(groupId: groupId))
        #expect(confirmation.memberWorkspaceIds == [anchorId])
        #expect(confirmation.containedWorkspaceCount == 0)

        let closed = groups.deleteWorkspaceGroup(confirmed: confirmation)

        #expect(closed == 1)
        #expect(host.closedWorkspaceIds == [anchorId])
        #expect(model.tabs.contains { $0.id == first.id && $0.groupId == nil })
        #expect(model.tabs.contains { $0.id == second.id && $0.groupId == nil })
        #expect(!model.workspaceGroups.contains { $0.id == groupId })
    }

    @Test
    func deleteAnchorOnlyGroupClosesHeaderWorkspaceAndCreatesReplacement() throws {
        let (model, host, groups) = makeWorld()
        model.tabs = []
        let groupId = try #require(groups.createWorkspaceGroup(name: "Empty", childWorkspaceIds: []))
        let group = try #require(model.workspaceGroups.first { $0.id == groupId })
        let anchorId = group.anchorWorkspaceId
        let confirmation = try #require(groups.deletionConfirmation(groupId: groupId))
        #expect(confirmation.memberWorkspaceIds == [anchorId])
        #expect(confirmation.containedWorkspaceCount == 0)

        let closed = groups.deleteWorkspaceGroup(confirmed: confirmation)

        #expect(closed == 1)
        #expect(host.closedWorkspaceIds == [anchorId])
        #expect(!model.tabs.contains { $0.id == anchorId })
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].groupId == nil)
        #expect(!model.workspaceGroups.contains { $0.id == groupId })
    }

    @Test
    func confirmedDeleteClosesOnlyConfirmedMembershipWhenGroupChangesDuringPrompt() throws {
        let (model, host, groups) = makeWorld()
        let first = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        let lateJoiner = CoordinatorStubTab()
        model.tabs = [first, second, lateJoiner]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [first.id, second.id]))
        let confirmation = try #require(groups.deletionConfirmation(groupId: groupId))
        #expect(confirmation.containedWorkspaceCount == 2)

        model.assignGroup(workspaceId: lateJoiner.id, groupId: groupId)
        let liveMembershipAfterPrompt = Set(model.tabs.filter { $0.groupId == groupId }.map(\.id))
        #expect(liveMembershipAfterPrompt.contains(lateJoiner.id))

        let closed = groups.deleteWorkspaceGroup(confirmed: confirmation)

        #expect(closed == confirmation.memberCount)
        #expect(Set(host.closedWorkspaceIds) == Set(confirmation.memberWorkspaceIds))
        #expect(host.closedWorkspaceIds.last == confirmation.anchorWorkspaceId)
        #expect(model.tabs.contains { $0.id == lateJoiner.id })
        #expect(model.tabs.first(where: { $0.id == lateJoiner.id })?.groupId == nil)
        #expect(!model.workspaceGroups.contains { $0.id == groupId })
    }
}
