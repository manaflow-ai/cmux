import Foundation
import Testing
@testable import CmuxWorkspaces

extension WorkspaceCoordinatorTests {
    @Test
    func collapseAllGroupsMovesHiddenFocusToAnchorAndReconcilesSelectionOnce() throws {
        let (model, host, groups, _) = makeWorld()
        let firstChild = CoordinatorStubTab()
        let secondChild = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [firstChild, secondChild, outside]
        let firstGroupId = try #require(groups.createWorkspaceGroup(name: "First", childWorkspaceIds: [firstChild.id]))
        let secondGroupId = try #require(groups.createWorkspaceGroup(name: "Second", childWorkspaceIds: [secondChild.id]))
        let firstGroup = try #require(model.workspaceGroups.first { $0.id == firstGroupId })
        let secondGroup = try #require(model.workspaceGroups.first { $0.id == secondGroupId })
        model.selectedTabId = secondChild.id
        host.sidebarSelectedWorkspaceIds = [firstChild.id, secondChild.id, outside.id]

        groups.collapseAllWorkspaceGroups()

        #expect(model.workspaceGroups.allSatisfy { $0.isCollapsed })
        #expect(model.selectedTabId == secondGroup.anchorWorkspaceId)
        #expect(host.selectedWorkspaceIds == [secondGroup.anchorWorkspaceId])
        #expect(host.subtractedSidebarSelections.count == 1)
        let reconciliation = try #require(host.subtractedSidebarSelections.first)
        #expect(reconciliation.hidden == [firstChild.id, secondChild.id])
        #expect(reconciliation.focused == secondGroup.anchorWorkspaceId)
        #expect(!reconciliation.hidden.contains(firstGroup.anchorWorkspaceId))
        #expect(!reconciliation.hidden.contains(secondGroup.anchorWorkspaceId))
    }

    @Test
    func collapseAllGroupsRepairsSelectionForGroupsAlreadyCollapsed() throws {
        let (model, host, groups, _) = makeWorld()
        let alreadyCollapsedChild = CoordinatorStubTab()
        let expandedChild = CoordinatorStubTab()
        model.tabs = [alreadyCollapsedChild, expandedChild]
        let alreadyCollapsedGroupId = try #require(groups.createWorkspaceGroup(name: "Already collapsed", childWorkspaceIds: [alreadyCollapsedChild.id]))
        let expandedGroupId = try #require(groups.createWorkspaceGroup(name: "Expanded", childWorkspaceIds: [expandedChild.id]))
        let alreadyCollapsedGroup = try #require(model.workspaceGroups.first { $0.id == alreadyCollapsedGroupId })
        let expandedGroup = try #require(model.workspaceGroups.first { $0.id == expandedGroupId })
        let alreadyCollapsedAnchor = alreadyCollapsedGroup.anchorWorkspaceId
        let expandedAnchor = expandedGroup.anchorWorkspaceId
        groups.setWorkspaceGroupCollapsed(groupId: alreadyCollapsedGroupId, isCollapsed: true)
        model.selectedTabId = alreadyCollapsedChild.id
        host.sidebarSelectedWorkspaceIds = [alreadyCollapsedChild.id, expandedChild.id]

        groups.collapseAllWorkspaceGroups()

        #expect(model.workspaceGroups.allSatisfy { $0.isCollapsed })
        #expect(model.selectedTabId == alreadyCollapsedAnchor)
        #expect(host.selectedWorkspaceIds == [alreadyCollapsedAnchor])
        #expect(host.subtractedSidebarSelections.count == 1)
        let reconciliation = try #require(host.subtractedSidebarSelections.first)
        #expect(reconciliation.hidden == Set([alreadyCollapsedChild.id, expandedChild.id]))
        #expect(reconciliation.focused == alreadyCollapsedAnchor)
        #expect(!reconciliation.hidden.contains(expandedAnchor))
    }

    @Test
    func collapseAllGroupsReconcilesFocusWhenSidebarSelectionIsStale() throws {
        let (model, host, groups, _) = makeWorld()
        let child = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [child, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "Stale selection", childWorkspaceIds: [child.id]))
        let group = try #require(model.workspaceGroups.first { $0.id == groupId })
        model.selectedTabId = child.id
        host.sidebarSelectedWorkspaceIds = [outside.id]

        groups.collapseAllWorkspaceGroups()

        #expect(model.selectedTabId == group.anchorWorkspaceId)
        #expect(host.subtractedSidebarSelections.count == 1)
        let reconciliation = try #require(host.subtractedSidebarSelections.first)
        #expect(reconciliation.hidden == Set([child.id]))
        #expect(reconciliation.focused == group.anchorWorkspaceId)
    }

    @Test
    func collapseAllGroupsReconcilesSelectionWhenFocusedAnchorIsAlreadySelected() throws {
        let (model, host, groups, _) = makeWorld()
        let child = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [child, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "Focused anchor", childWorkspaceIds: [child.id]))
        let group = try #require(model.workspaceGroups.first { $0.id == groupId })
        model.selectedTabId = group.anchorWorkspaceId
        host.sidebarSelectedWorkspaceIds = [child.id]

        groups.collapseAllWorkspaceGroups()

        #expect(model.selectedTabId == group.anchorWorkspaceId)
        #expect(host.subtractedSidebarSelections.count == 1)
        let reconciliation = try #require(host.subtractedSidebarSelections.first)
        #expect(reconciliation.hidden == Set([child.id]))
        #expect(reconciliation.focused == group.anchorWorkspaceId)
    }

    @Test
    func collapseAllGroupsDoesNotHideMembersWithoutALiveAnchor() throws {
        let (model, host, groups, _) = makeWorld()
        let groupId = UUID()
        let emptyGroup = WorkspaceGroup(
            id: groupId,
            name: "Empty",
            isCollapsed: false,
            isPinned: true,
            anchor: .empty(groupId),
            customColor: nil,
            iconSymbol: nil
        )
        let orphanedMember = CoordinatorStubTab(groupId: groupId)
        let outside = CoordinatorStubTab()
        model.tabs = [orphanedMember, outside]
        model.workspaceGroups = [emptyGroup]
        model.selectedTabId = orphanedMember.id
        host.sidebarSelectedWorkspaceIds = [orphanedMember.id]

        groups.collapseAllWorkspaceGroups()

        #expect(model.workspaceGroups.allSatisfy { $0.isCollapsed })
        #expect(model.selectedTabId == orphanedMember.id)
        #expect(host.sidebarSelectedWorkspaceIds == [orphanedMember.id])
        #expect(host.selectedWorkspaceIds.isEmpty)
        #expect(host.subtractedSidebarSelections.isEmpty)
    }

    @Test
    func expandAllGroupsPreservesFocusAndSelection() throws {
        let (model, host, groups, _) = makeWorld()
        let firstChild = CoordinatorStubTab()
        let secondChild = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [firstChild, secondChild, outside]
        let firstGroupId = try #require(groups.createWorkspaceGroup(name: "First", childWorkspaceIds: [firstChild.id]))
        let secondGroupId = try #require(groups.createWorkspaceGroup(name: "Second", childWorkspaceIds: [secondChild.id]))
        groups.setWorkspaceGroupCollapsed(groupId: firstGroupId, isCollapsed: true)
        groups.setWorkspaceGroupCollapsed(groupId: secondGroupId, isCollapsed: true)
        model.selectedTabId = outside.id
        host.sidebarSelectedWorkspaceIds = [outside.id]

        groups.expandAllWorkspaceGroups()

        #expect(model.workspaceGroups.allSatisfy { !$0.isCollapsed })
        #expect(model.selectedTabId == outside.id)
        #expect(host.sidebarSelectedWorkspaceIds == [outside.id])
        #expect(host.selectedWorkspaceIds.isEmpty)
        #expect(host.subtractedSidebarSelections.isEmpty)
    }
}
