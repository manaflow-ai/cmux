import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

@MainActor
private final class CoordinatorStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool
    var currentDirectory: String

    init(
        groupId: UUID? = nil,
        isPinned: Bool = false,
        currentDirectory: String = "/tmp"
    ) {
        self.id = UUID()
        self.groupId = groupId
        self.isPinned = isPinned
        self.currentDirectory = currentDirectory
    }
}

/// Window-side stand-in: creates stub workspaces on demand, records every
/// inverted effect, and removes closed tabs from the model like the real
/// `closeWorkspace` teardown does.
@MainActor
private final class StubGroupHost: WorkspaceGroupHosting {
    typealias Tab = CoordinatorStubTab

    let model: WorkspacesModel<CoordinatorStubTab>
    private(set) var orderChanges: [[UUID]] = []
    private(set) var closedWorkspaceIds: [UUID] = []
    private(set) var selectedWorkspaceIds: [UUID] = []
    private(set) var subtractedSidebarSelections: [(hidden: Set<UUID>, focused: UUID?)] = []
    private(set) var collapsedForCreation: [(hidden: Set<UUID>, anchor: UUID)] = []
    var sidebarSelectedWorkspaceIds: Set<UUID> = []
    var localizedAutoGroupNameFormat: String { "Group %lld" }
    var defaultNewWorkspacePlacementInGroup: WorkspaceGroupNewPlacement { .end }
    private(set) var groupNameChangeCount = 0

    init(model: WorkspacesModel<CoordinatorStubTab>) {
        self.model = model
    }

    func workspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
        guard !movedWorkspaceIds.isEmpty else { return }
        orderChanges.append(movedWorkspaceIds)
    }

    func createGroupAnchorWorkspace(
        title: String,
        workingDirectory: String?,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> CoordinatorStubTab {
        let tab = CoordinatorStubTab(currentDirectory: workingDirectory ?? "/tmp")
        // Legacy addWorkspace(placementOverride: .top) inserts after pinned.
        let pinnedCount = model.tabs.prefix(while: \.isPinned).count
        model.tabs.insert(tab, at: pinnedCount)
        if select { model.selectedTabId = tab.id }
        return tab
    }

    func createWorkspaceForGroup(
        workingDirectory: String?,
        initialSurface: NewWorkspaceInitialSurface,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> CoordinatorStubTab {
        let tab = CoordinatorStubTab(currentDirectory: workingDirectory ?? "/tmp")
        model.tabs.append(tab)
        if select { model.selectedTabId = tab.id }
        return tab
    }

    func closeWorkspaceForGroupDeletion(_ tab: CoordinatorStubTab, recordHistory: Bool) {
        closedWorkspaceIds.append(tab.id)
        guard model.tabs.count > 1,
              let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        model.tabs.remove(at: index)
        model.dissolveGroupsAnchoredBy(closedWorkspaceId: tab.id)
    }

    func selectWorkspace(_ tab: CoordinatorStubTab) {
        selectedWorkspaceIds.append(tab.id)
        model.selectedTabId = tab.id
    }

    func collapseSidebarSelectionForGroupCreation(hiddenWorkspaceIds: Set<UUID>, anchorId: UUID) {
        collapsedForCreation.append((hiddenWorkspaceIds, anchorId))
        sidebarSelectedWorkspaceIds = [anchorId]
    }

    func subtractSidebarSelection(hiddenWorkspaceIds: Set<UUID>, focusedWorkspaceId: UUID?) {
        subtractedSidebarSelections.append((hiddenWorkspaceIds, focusedWorkspaceId))
        sidebarSelectedWorkspaceIds.subtract(hiddenWorkspaceIds)
    }

    func normalizedGroupIconSymbol(_ symbol: String?) -> String? { symbol }

    func workspaceGroupNameDidChange() { groupNameChangeCount += 1 }
}

@MainActor
struct WorkspaceCoordinatorTests {
    private func makeWorld() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: StubGroupHost,
        groups: WorkspaceGroupCoordinator<CoordinatorStubTab>,
        reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>
    ) {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = StubGroupHost(model: model)
        let groups = WorkspaceGroupCoordinator(model: model)
        groups.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        return (model, host, groups, reorder)
    }

    // MARK: Reorder

    @Test
    func moveTabsToTopKeepsPinnedTierAboveUnpinned() {
        let (model, host, _, reorder) = makeWorld()
        let pinnedA = CoordinatorStubTab(isPinned: true)
        let pinnedB = CoordinatorStubTab(isPinned: true)
        let plain1 = CoordinatorStubTab()
        let plain2 = CoordinatorStubTab()
        model.tabs = [pinnedA, pinnedB, plain1, plain2]
        reorder.moveTabsToTop([plain2.id, pinnedB.id])
        #expect(model.tabs.map(\.id) == [pinnedB.id, pinnedA.id, plain2.id, plain1.id])
        #expect(host.orderChanges.last?.sorted(by: { $0.uuidString < $1.uuidString })
            == [pinnedB.id, plain2.id].sorted(by: { $0.uuidString < $1.uuidString }))
    }

    @Test
    func reorderWorkspaceClampsUnpinnedAbovePinnedBoundary() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let pinned = CoordinatorStubTab(isPinned: true)
        let plain1 = CoordinatorStubTab()
        let plain2 = CoordinatorStubTab()
        model.tabs = [pinned, plain1, plain2]

        // Unpinned dragged to index 0 clamps below the pinned row.
        #expect(reorder.reorderWorkspace(tabId: plain2.id, toIndex: 0))
        #expect(model.tabs.map(\.id) == [pinned.id, plain2.id, plain1.id])
    }

    @Test
    func reorderWorkspaceBeforeDownwardMoveInsertsAtExpectedSlot() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        model.tabs = [a, b, c]
        #expect(reorder.reorderWorkspace(tabId: a.id, before: c.id))
        #expect(model.tabs.map(\.id) == [b.id, a.id, c.id])
    }

    @Test
    func reorderWorkspaceAfterDownwardMoveInsertsAtExpectedSlot() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        model.tabs = [a, b, c]
        #expect(reorder.reorderWorkspace(tabId: a.id, after: b.id))
        #expect(model.tabs.map(\.id) == [b.id, a.id, c.id])
    }

    @Test
    func batchReorderRejectsUnknownAndDuplicateIds() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        model.tabs = [a, b]

        let unknown = UUID()
        guard case .failure(.workspaceNotFound(let missing)) =
            reorder.reorderWorkspaces(orderedWorkspaceIds: [unknown]) else {
            Issue.record("expected workspaceNotFound")
            return
        }
        #expect(missing == unknown)

        guard case .failure(.duplicateWorkspace) =
            reorder.reorderWorkspaces(orderedWorkspaceIds: [a.id, a.id]) else {
            Issue.record("expected duplicateWorkspace")
            return
        }
    }

    @Test
    func setPinnedBatchUnpinKeepsRequestOrderAtUnpinnedFront() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab(isPinned: true)
        let b = CoordinatorStubTab(isPinned: true)
        let c = CoordinatorStubTab()
        model.tabs = [a, b, c]

        let changed = reorder.setPinned(workspaceIds: [a.id, b.id], pinned: false)
        #expect(changed == [a.id, b.id])
        // Parity with the one-at-a-time path: each unpin inserts at the
        // front of the unpinned segment (a first → [a, c], then b in front
        // → [b, a, c]), which the batch path reproduces by reversing the
        // changed input order.
        #expect(model.tabs.map(\.id) == [b.id, a.id, c.id])
        #expect(model.tabs.allSatisfy { !$0.isPinned })
    }

    @Test
    func explicitGroupDropJoinsTargetGroupAtBoundarySlot() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let dragged = CoordinatorStubTab()
        let child1 = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [dragged, child1, child2, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            child1.id,
            child2.id,
        ]))
        let group = try #require(model.workspaceGroups.first(where: { $0.id == groupId }))

        let moved = reorder.reorderSidebarWorkspace(
            tabId: dragged.id,
            toIndex: 3,
            isDragOperation: true,
            explicitGroupId: groupId
        )
        #expect(moved)
        #expect(dragged.groupId == groupId)
        #expect(model.tabs.map(\.id) == [
            group.anchorWorkspaceId,
            child1.id,
            child2.id,
            dragged.id,
            outside.id,
        ])
    }

    @Test
    func explicitGroupDropAppliesMembershipWhenIndexDoesNotMove() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let child1 = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        let dragged = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [child1, child2, dragged, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            child1.id,
            child2.id,
        ]))
        let draggedIndex = try #require(model.tabs.firstIndex { $0.id == dragged.id })

        let moved = reorder.reorderSidebarWorkspace(
            tabId: dragged.id,
            toIndex: draggedIndex,
            isDragOperation: true,
            explicitGroupId: groupId
        )
        #expect(moved)
        #expect(dragged.groupId == groupId)
    }

    @Test
    func explicitGroupDropOfSelectedWorkspaceExpandsCollapsedTargetGroupWhenIndexDoesNotMove() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let child = CoordinatorStubTab()
        let dragged = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [child, dragged, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            child.id,
        ]))
        groups.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: true)
        model.selectedTabId = dragged.id
        let draggedIndex = try #require(model.tabs.firstIndex { $0.id == dragged.id })

        let moved = reorder.reorderSidebarWorkspace(
            tabId: dragged.id,
            toIndex: draggedIndex,
            isDragOperation: true,
            explicitGroupId: groupId
        )
        #expect(moved)
        #expect(dragged.groupId == groupId)
        #expect(model.selectedTabId == dragged.id)
        #expect(model.workspaceGroups.first { $0.id == groupId }?.isCollapsed == false)
    }

    @Test
    func staleExplicitGroupDropDoesNotInferMembership() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let child1 = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        let dragged = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [child1, child2, dragged, outside]
        _ = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            child1.id,
            child2.id,
        ]))
        let draggedIndex = try #require(model.tabs.firstIndex { $0.id == dragged.id })
        let previousOrder = model.tabs.map(\.id)

        let moved = reorder.reorderSidebarWorkspace(
            tabId: dragged.id,
            toIndex: draggedIndex,
            isDragOperation: true,
            explicitGroupId: UUID()
        )
        #expect(!moved)
        #expect(dragged.groupId == nil)
        #expect(model.tabs.map(\.id) == previousOrder)
    }

    @Test
    func explicitGroupDropFromAnotherGroupPreservesTargetGroupSlot() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let dragged = CoordinatorStubTab()
        let sourcePeer = CoordinatorStubTab()
        let targetChild1 = CoordinatorStubTab()
        let targetChild2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [dragged, sourcePeer, targetChild1, targetChild2, outside]
        _ = try #require(groups.createWorkspaceGroup(name: "Source", childWorkspaceIds: [
            dragged.id,
            sourcePeer.id,
        ]))
        let targetGroupId = try #require(groups.createWorkspaceGroup(name: "Target", childWorkspaceIds: [
            targetChild1.id,
            targetChild2.id,
        ]))
        let targetGroup = try #require(model.workspaceGroups.first { $0.id == targetGroupId })
        let targetLastIndex = try #require(model.tabs.indices.last { model.tabs[$0].groupId == targetGroupId })

        let moved = reorder.reorderSidebarWorkspace(
            tabId: dragged.id,
            toIndex: targetLastIndex,
            isDragOperation: true,
            explicitGroupId: targetGroupId
        )
        #expect(moved)
        #expect(dragged.groupId == targetGroupId)
        #expect(model.tabs.filter { $0.groupId == targetGroupId }.map(\.id) == [
            targetGroup.anchorWorkspaceId,
            targetChild1.id,
            targetChild2.id,
            dragged.id,
        ])
    }

    @Test
    func boundaryDropWithoutExplicitGroupStaysTopLevel() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let dragged = CoordinatorStubTab()
        let child1 = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [dragged, child1, child2, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            child1.id,
            child2.id,
        ]))
        let group = try #require(model.workspaceGroups.first(where: { $0.id == groupId }))

        let moved = reorder.reorderSidebarWorkspace(
            tabId: dragged.id,
            toIndex: 3,
            isDragOperation: true
        )
        #expect(moved)
        #expect(dragged.groupId == nil)
        #expect(model.tabs.map(\.id) == [
            group.anchorWorkspaceId,
            child1.id,
            child2.id,
            dragged.id,
            outside.id,
        ])
    }

    @Test
    func topLevelDropOverGroupMemberDoesNotInferMembership() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let dragged = CoordinatorStubTab()
        let child1 = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [dragged, child1, child2, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            child1.id,
            child2.id,
        ]))
        let group = try #require(model.workspaceGroups.first(where: { $0.id == groupId }))

        let moved = reorder.reorderSidebarWorkspace(
            tabId: dragged.id,
            toIndex: 1,
            isDragOperation: true,
            usesTopLevelRows: true
        )
        #expect(moved)
        #expect(dragged.groupId == nil)
        #expect(model.tabs.map(\.id) == [
            group.anchorWorkspaceId,
            child1.id,
            child2.id,
            dragged.id,
            outside.id,
        ])
    }

    @Test
    func explicitGroupLegalRangeConstrainsBoundaryPlanningToGroup() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let dragged = CoordinatorStubTab()
        let child1 = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [dragged, child1, child2, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            child1.id,
            child2.id,
        ]))
        let memberIndices = model.tabs.indices.filter { model.tabs[$0].groupId == groupId }
        let firstMemberIndex = try #require(memberIndices.first)
        let lastMemberIndex = try #require(memberIndices.last)

        let unconstrainedRange = reorder.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: dragged.id,
            targetWorkspaceId: outside.id
        )
        let explicitGroupRange = reorder.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: dragged.id,
            targetWorkspaceId: outside.id,
            explicitGroupId: groupId
        )
        #expect(unconstrainedRange == nil)
        #expect(explicitGroupRange == (firstMemberIndex + 1)...(lastMemberIndex + 1))
    }

    // MARK: Groups

    @Test
    func createWorkspaceGroupAdoptsChildrenAndKeepsSectionContiguous() throws {
        let (model, host, groups, _) = makeWorld()
        let child1 = CoordinatorStubTab()
        let other = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        model.tabs = [child1, other, child2]

        let groupId = groups.createWorkspaceGroup(
            name: " ",
            childWorkspaceIds: [child1.id, child2.id]
        )

        let group = try #require(model.workspaceGroups.first(where: { $0.id == groupId }))
        #expect(group.name == "Group 1")
        let anchorId = group.anchorWorkspaceId
        #expect(model.tabs.first(where: { $0.id == child1.id })?.groupId == groupId)
        #expect(model.tabs.first(where: { $0.id == child2.id })?.groupId == groupId)
        // Section is contiguous and anchor-first at the first child's slot.
        #expect(model.tabs.map(\.id) == [anchorId, child1.id, child2.id, other.id])
        #expect(host.orderChanges.last == [anchorId, child1.id, child2.id])
    }

    @Test
    func createWorkspaceGroupRefusesForeignAnchorsAsChildren() {
        let (model, host, groups, _) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        model.tabs = [a]
        let firstGroupId = groups.createWorkspaceGroup(name: "One", childWorkspaceIds: [a.id])
        let firstAnchor = model.workspaceGroups[0].anchorWorkspaceId

        _ = groups.createWorkspaceGroup(name: "Two", childWorkspaceIds: [firstAnchor])

        // The foreign anchor keeps its original membership.
        #expect(model.tabs.first(where: { $0.id == firstAnchor })?.groupId == firstGroupId)
    }

    @Test
    func deleteWorkspaceGroupClosesMembersAndClearsLastHoldout() throws {
        let (model, host, groups, _) = makeWorld()
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        model.tabs = [a, b]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))

        let closed = groups.deleteWorkspaceGroup(groupId: groupId)

        // Anchor + one member close for real; the final holdout is kept
        // alive as an ungrouped workspace (closeWorkspace's last-tab guard).
        #expect(closed == 2)
        #expect(host.closedWorkspaceIds.count >= 2)
        #expect(model.workspaceGroups.isEmpty)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].groupId == nil)
    }

    @Test
    func ungroupKeepsMemberPositionsAndDropsMembership() throws {
        let (model, host, groups, _) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        model.tabs = [a]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id]))
        let orderBefore = model.tabs.map(\.id)

        groups.ungroupWorkspaceGroup(groupId: groupId)
        #expect(model.workspaceGroups.isEmpty)
        #expect(model.tabs.map(\.id) == orderBefore)
        #expect(model.tabs.allSatisfy { $0.groupId == nil })
    }

    @Test
    func collapseToggleMovesFocusToAnchorAndStripsHiddenSelection() throws {
        let (model, host, groups, _) = makeWorld()
        let a = CoordinatorStubTab()
        model.tabs = [a]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id]))
        let anchorId = model.workspaceGroups[0].anchorWorkspaceId
        model.selectedTabId = a.id
        host.sidebarSelectedWorkspaceIds = [a.id]

        groups.toggleWorkspaceGroupCollapsed(groupId: groupId)
        #expect(host.selectedWorkspaceIds == [anchorId])
        #expect(host.subtractedSidebarSelections.count == 1)
        #expect(host.subtractedSidebarSelections[0].hidden == [a.id])
        #expect(model.workspaceGroups[0].isCollapsed)
    }

    @Test
    func anchorCloseDissolvesGroupAndRenormalizes() {
        let (model, host, groups, _) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [a, outside]
        _ = groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id])
        let anchorId = model.workspaceGroups[0].anchorWorkspaceId

        if let index = model.tabs.firstIndex(where: { $0.id == anchorId }) {
            model.tabs.remove(at: index)
        }
        model.dissolveGroupsAnchoredBy(closedWorkspaceId: anchorId)
        #expect(model.workspaceGroups.isEmpty)
        #expect(model.tabs.allSatisfy { $0.groupId == nil })
    }

    @Test
    func setWorkspaceGroupAnchorHoistsNewAnchorToSectionFront() throws {
        let (model, host, groups, _) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        model.tabs = [a, b]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))

        groups.setWorkspaceGroupAnchor(groupId: groupId, workspaceId: b.id)
        #expect(model.workspaceGroups[0].anchorWorkspaceId == b.id)
        let memberIds = model.tabs.filter { $0.groupId == groupId }.map(\.id)
        #expect(memberIds.first == b.id)
    }
}
