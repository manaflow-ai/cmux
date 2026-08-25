import Foundation
import Testing
import CmuxSettings
@testable import CmuxWorkspaces

@MainActor
final class CoordinatorStubTab: WorkspaceTabRepresenting {
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

/// Window-side stand-in for group/reorder coordinator tests.
@MainActor
final class StubGroupHost: WorkspaceGroupHosting {
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
        let pinnedCount = model.tabs.prefix(while: \.isPinned).count
        model.tabs.insert(tab, at: pinnedCount)
        if select { model.selectedTabId = tab.id }
        return tab
    }

    func createWorkspaceForGroup(
        title: String?,
        workingDirectory: String?,
        initialSurface: NewWorkspaceInitialSurface,
        initialBrowserURL: URL?,
        initialBrowserOmnibarVisible: Bool,
        initialBrowserTransparentBackground: Bool,
        inheritWorkingDirectory: Bool,
        select: Bool,
        applyCreationTitleAsCustomTitle: Bool
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
    func notificationBumpTreatsSidebarDividerAsSegmentBarrier() {
        let (model, _, _, reorder) = makeWorld()
        let first = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        let bumped = CoordinatorStubTab()
        let destination = CoordinatorStubTab()
        model.tabs = [first, second, bumped, destination]
        _ = model.insertSidebarDivider(after: second.id)

        reorder.moveTabToTopForNotification(destination.id)

        #expect(model.tabs.map(\.id) == [first.id, second.id, destination.id, bumped.id])
        #expect(model.sidebarDivider(after: second.id) != nil)
    }

    @Test
    func workspaceReorderPreservesDividerAnchoredToMovedWorkspace() {
        let (model, _, _, reorder) = makeWorld()
        let first = CoordinatorStubTab()
        let second = CoordinatorStubTab()
        let third = CoordinatorStubTab()
        let fourth = CoordinatorStubTab()
        model.tabs = [first, second, third, fourth]
        _ = model.insertSidebarDivider(after: first.id)

        #expect(reorder.reorderWorkspace(tabId: first.id, toIndex: 1))
        #expect(model.tabs.map(\.id) == [second.id, first.id, third.id, fourth.id])
        #expect(model.sidebarDivider(after: first.id) != nil)
    }

    @Test
    func reorderWorkspaceClampsUnpinnedAbovePinnedBoundary() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let pinned = CoordinatorStubTab(isPinned: true)
        let plain1 = CoordinatorStubTab()
        let plain2 = CoordinatorStubTab()
        model.tabs = [pinned, plain1, plain2]

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

    @Test
    func sidebarBlockLandsContiguouslyAtGapInSourceOrder() {
        let (model, host, _, reorder) = makeWorld()
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        let d = CoordinatorStubTab()
        let e = CoordinatorStubTab()
        model.tabs = [a, b, c, d, e]
        model.selectedTabId = c.id

        // Grabbed b, dropped at the gap between d and e: the planner's index
        // is b's final position in [a, c, d, e] (order without the grab row).
        let moved = reorder.reorderSidebarWorkspaces(
            tabIds: [b.id, d.id],
            draggedTabId: b.id,
            toIndex: 3,
            isDragOperation: true
        )

        #expect(moved)
        #expect(model.tabs.map(\.id) == [a.id, c.id, b.id, d.id, e.id])
        #expect(model.selectedTabId == c.id)
        #expect(host.orderChanges == [[b.id, d.id]])
    }

    @Test
    func sidebarBlockDropAtBottomGapAppends() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        let d = CoordinatorStubTab()
        let e = CoordinatorStubTab()
        model.tabs = [a, b, c, d, e]

        // Grabbed b, dropped below e: the planner emits index 4, past the end
        // of [a, c, d, e]. Anchoring that to the last row instead of appending
        // was the block-drop off-by-one.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [b.id, d.id],
            draggedTabId: b.id,
            toIndex: 4,
            isDragOperation: true
        ))
        #expect(model.tabs.map(\.id) == [a.id, c.id, e.id, b.id, d.id])
    }

    @Test
    func sidebarBlockSpanningGapStillLandsContiguously() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        let d = CoordinatorStubTab()
        let e = CoordinatorStubTab()
        model.tabs = [a, b, c, d, e]

        // Grabbed a, dropped at the gap between b and c (index 1 in
        // [b, c, d, e]); d joins the block from below the gap.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [a.id, d.id],
            draggedTabId: a.id,
            toIndex: 1,
            isDragOperation: true
        ))
        #expect(model.tabs.map(\.id) == [b.id, a.id, d.id, c.id, e.id])
    }

    @Test
    func sidebarNoncontiguousBlockCoalescesAtDraggedRowsOwnGap() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        let d = CoordinatorStubTab()
        let e = CoordinatorStubTab()
        model.tabs = [a, b, c, d, e]

        // Grabbed b with {b, d} selected and dropped at b's own lower gap
        // (index 1 in [a, c, d, e]): b stays put and d coalesces up to it.
        // This gap paints an indicator only for noncontiguous blocks
        // (SidebarWorkspaceDragBlockResolver.blockOccupiesNoncontiguousRows).
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [b.id, d.id],
            draggedTabId: b.id,
            toIndex: 1,
            isDragOperation: true
        ))
        #expect(model.tabs.map(\.id) == [a.id, b.id, d.id, c.id, e.id])
    }

    @Test
    func sidebarBlockClampsMixedPinTiersAndKeepsEachContiguous() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let pinned1 = CoordinatorStubTab(isPinned: true)
        let pinned2 = CoordinatorStubTab(isPinned: true)
        let pinned3 = CoordinatorStubTab(isPinned: true)
        let plain1 = CoordinatorStubTab()
        let plain2 = CoordinatorStubTab()
        let plain3 = CoordinatorStubTab()
        let plain4 = CoordinatorStubTab()
        model.tabs = [pinned1, pinned2, pinned3, plain1, plain2, plain3, plain4]

        // Grabbed plain2, dropped at the pinned/unpinned boundary (index 3 in
        // the order without plain2): each tier clamps into its own region.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [pinned1.id, pinned3.id, plain2.id, plain4.id],
            draggedTabId: plain2.id,
            toIndex: 3,
            isDragOperation: true
        ))
        #expect(model.tabs.map(\.id) == [
            pinned2.id,
            pinned1.id,
            pinned3.id,
            plain2.id,
            plain4.id,
            plain1.id,
            plain3.id,
        ])
    }

    @Test
    func sidebarBlockExplicitGroupDropAssignsEveryMember() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let moving1 = CoordinatorStubTab()
        let moving2 = CoordinatorStubTab()
        let target1 = CoordinatorStubTab()
        let target2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [moving1, moving2, target1, target2, outside]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [target1.id, target2.id]
        ))
        let group = try #require(model.workspaceGroups.first { $0.id == groupId })
        // Grabbed moving1; the gap above target2 indexes the order without
        // the grab row, so the raw position shifts down by one.
        let targetIndex = try #require(
            model.tabs.filter { $0.id != moving1.id }.firstIndex { $0.id == target2.id }
        )

        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [moving1.id, moving2.id],
            draggedTabId: moving1.id,
            toIndex: targetIndex,
            isDragOperation: true,
            explicitGroupId: groupId
        ))
        #expect(moving1.groupId == groupId)
        #expect(moving2.groupId == groupId)
        #expect(model.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            target1.id,
            moving1.id,
            moving2.id,
            target2.id,
        ])
    }

    @Test
    func sidebarBlockPlainGroupGapAbsorbsEveryMember() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let moving1 = CoordinatorStubTab()
        let moving2 = CoordinatorStubTab()
        let target1 = CoordinatorStubTab()
        let target2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [moving1, moving2, target1, target2, outside]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [target1.id, target2.id]
        ))
        let targetIndex = try #require(
            model.tabs.filter { $0.id != moving1.id }.firstIndex { $0.id == target2.id }
        )

        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [moving1.id, moving2.id],
            draggedTabId: moving1.id,
            toIndex: targetIndex,
            isDragOperation: true
        ))
        #expect(moving1.groupId == groupId)
        #expect(moving2.groupId == groupId)
    }

    @Test
    func sidebarBlockAmbiguousGroupBoundaryPreservesMembership() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let loose = CoordinatorStubTab()
        let member1 = CoordinatorStubTab()
        let member2 = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [loose, member1, member2, outside]
        let groupId = try #require(groups.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [member1.id, member2.id]
        ))
        let anchorId = try #require(model.workspaceGroups.first?.anchorWorkspaceId)
        // Grabbed loose; the gap between member2 and outside has one grouped
        // and one ungrouped neighbor. Single-drag preserves membership there,
        // so the block must too — stripping member2 out of its group here was
        // the divergence this test pins down.
        let targetIndex = try #require(
            model.tabs.filter { $0.id != loose.id }.firstIndex { $0.id == outside.id }
        )

        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [loose.id, member2.id],
            draggedTabId: loose.id,
            toIndex: targetIndex,
            isDragOperation: true
        ))
        #expect(loose.groupId == nil)
        #expect(member2.groupId == groupId)
        #expect(model.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            anchorId,
            member1.id,
            member2.id,
        ])
    }

    @Test
    func sidebarBlockTopLevelDropPromotesGroupedChildren() throws {
        let (model, host, groups, reorder) = makeWorld()
        _ = host
        let child1 = CoordinatorStubTab()
        let child2 = CoordinatorStubTab()
        let outside1 = CoordinatorStubTab()
        let outside2 = CoordinatorStubTab()
        model.tabs = [child1, child2, outside1, outside2]
        _ = try #require(groups.createWorkspaceGroup(
            name: "G",
            childWorkspaceIds: [child1.id, child2.id]
        ))
        let anchorId = try #require(model.workspaceGroups.first?.anchorWorkspaceId)

        // Grabbed child1; index 2 in the top-level rows without it
        // ([anchor, outside1, outside2]) is the gap above outside2.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [child1.id, child2.id],
            draggedTabId: child1.id,
            toIndex: 2,
            isDragOperation: true,
            usesTopLevelRows: true
        ))
        #expect(child1.groupId == nil)
        #expect(child2.groupId == nil)
        #expect(model.tabs.map(\.id) == [
            anchorId,
            outside1.id,
            child1.id,
            child2.id,
            outside2.id,
        ])
    }

    @Test
    func sidebarSingleElementBlockMatchesSingleWorkspaceAPI() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        let d = CoordinatorStubTab()
        model.tabs = [a, b, c, d]

        let blockResult = reorder.reorderSidebarWorkspaces(
            tabIds: [a.id],
            draggedTabId: a.id,
            toIndex: 2,
            isDragOperation: true
        )
        let blockOrder = model.tabs.map(\.id)

        model.tabs = [a, b, c, d]
        let singleResult = reorder.reorderSidebarWorkspace(
            tabId: a.id,
            toIndex: 2,
            isDragOperation: true
        )

        #expect(blockResult == singleResult)
        #expect(blockOrder == model.tabs.map(\.id))
    }

    @Test
    func sidebarBlockReferenceInsideSelectionWalksToNextRow() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        let d = CoordinatorStubTab()
        let e = CoordinatorStubTab()
        model.tabs = [a, b, c, d, e]

        // Grabbed b, dropped at index 2 of [a, c, d, e] — that slot is d,
        // itself a block member, so the reference walks forward to e.
        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [b.id, d.id],
            draggedTabId: b.id,
            toIndex: 2,
            isDragOperation: true
        ))
        #expect(model.tabs.map(\.id) == [a.id, c.id, b.id, d.id, e.id])
    }

    @Test
    func sidebarBlockIgnoresWorkspaceIdsMissingFromLiveTabs() {
        let (model, host, _, reorder) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let c = CoordinatorStubTab()
        model.tabs = [a, b, c]

        #expect(reorder.reorderSidebarWorkspaces(
            tabIds: [b.id, UUID()],
            draggedTabId: b.id,
            toIndex: 0,
            isDragOperation: true
        ))
        #expect(model.tabs.map(\.id) == [b.id, a.id, c.id])
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
    func createWorkspaceGroupAdoptsPinnedChildren() throws {
        let (model, host, groups, _) = makeWorld()
        let pinnedChild = CoordinatorStubTab(isPinned: true)
        let unpinnedChild = CoordinatorStubTab()
        model.tabs = [pinnedChild, unpinnedChild]

        let groupId = try #require(groups.createWorkspaceGroup(
            name: "Mixed",
            childWorkspaceIds: [pinnedChild.id, unpinnedChild.id]
        ))
        let group = try #require(model.workspaceGroups.first { $0.id == groupId })

        #expect(pinnedChild.groupId == groupId)
        #expect(unpinnedChild.groupId == groupId)
        #expect(model.tabs.filter { $0.groupId == groupId }.map(\.id) == [
            group.anchorWorkspaceId,
            pinnedChild.id,
            unpinnedChild.id,
        ])
        #expect(host.orderChanges.last == [
            group.anchorWorkspaceId,
            pinnedChild.id,
            unpinnedChild.id,
        ])
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
    func deleteWorkspaceGroupClosesMembersAndCreatesReplacementForLastHoldout() throws {
        let (model, host, groups, _) = makeWorld()
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        model.tabs = [a, b]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))

        let closed = groups.deleteWorkspaceGroup(groupId: groupId)

        // The group anchor and all members close for real. A replacement ungrouped
        // workspace is created when the final member would hit the last-tab guard.
        #expect(closed == 3)
        #expect(host.closedWorkspaceIds.count >= 3)
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

    /// Closing a group's anchor must delete only that workspace and keep the
    /// group intact by promoting the next member, instead of scattering the
    /// remaining members out to the ungrouped root tier.
    @Test
    func anchorClosePromotesNextMemberAndKeepsGroup() throws {
        let (model, host, groups, _) = makeWorld()
        _ = host
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        model.tabs = [a, b]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))
        let anchorId = model.workspaceGroups[0].anchorWorkspaceId
        // createWorkspaceGroup mints a fresh synthetic anchor; `a`/`b` are members.
        #expect(anchorId != a.id)
        #expect(anchorId != b.id)
        // `a` precedes `b` in tabs order, so `a` is the deterministic promotion
        // target once the anchor is removed.
        let aIndex = try #require(model.tabs.firstIndex(where: { $0.id == a.id }))
        let bIndex = try #require(model.tabs.firstIndex(where: { $0.id == b.id }))
        #expect(aIndex < bIndex)

        // Simulate the close path: the anchor is removed from tabs, then the
        // model's close-path group fixup runs.
        if let index = model.tabs.firstIndex(where: { $0.id == anchorId }) {
            model.tabs.remove(at: index)
        }
        model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: anchorId)

        // The group survives with the FIRST remaining member in tabs order (`a`,
        // not `b`) promoted to anchor; both members stay grouped and neither is
        // released to root.
        #expect(model.workspaceGroups.count == 1)
        #expect(model.workspaceGroups.first?.id == groupId)
        #expect(model.workspaceGroups.first?.anchorWorkspaceId == a.id)
        #expect(a.groupId == groupId)
        #expect(b.groupId == groupId)
    }

    /// Closing the anchor of a group with no other members removes the now-empty
    /// group (nothing left to promote).
    @Test
    func anchorCloseRemovesGroupWhenNoMembersRemain() throws {
        let (model, host, groups, _) = makeWorld()
        _ = host
        let outside = CoordinatorStubTab()
        model.tabs = [outside]
        _ = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: []))
        let anchorId = model.workspaceGroups[0].anchorWorkspaceId

        if let index = model.tabs.firstIndex(where: { $0.id == anchorId }) {
            model.tabs.remove(at: index)
        }
        model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: anchorId)

        #expect(model.workspaceGroups.isEmpty)
        #expect(model.tabs.map(\.id) == [outside.id])
    }

    /// If the snapshot anchor is closed while the Delete Group confirmation is
    /// open, the group promotes its next member to anchor. On acceptance the
    /// batch close must drain that *live* anchor last, not the stale snapshot
    /// anchor: closing the live anchor mid-batch would re-promote and
    /// renormalize the whole collection on every step (the O(k x totalTabs)
    /// churn `anchorLastCloseOrder` prevents). Proven by the close order.
    @Test
    func deleteGroupDrainsLiveAnchorLastWhenSnapshotAnchorClosedDuringConfirmation() throws {
        let (model, host, groups, _) = makeWorld()
        let a = CoordinatorStubTab()
        let b = CoordinatorStubTab()
        let outside = CoordinatorStubTab()
        model.tabs = [a, b, outside]
        let groupId = try #require(groups.createWorkspaceGroup(name: "G", childWorkspaceIds: [a.id, b.id]))

        // Snapshot the confirmation while the original synthetic anchor is live.
        let confirmation = try #require(groups.deletionConfirmation(groupId: groupId))
        let snapshotAnchorId = confirmation.anchorWorkspaceId
        #expect(snapshotAnchorId != a.id)
        #expect(snapshotAnchorId != b.id)

        // Another entrypoint closes the snapshot anchor during the modal loop:
        // `a` (first remaining member in tabs order) is promoted to live anchor.
        let anchorIndex = try #require(model.tabs.firstIndex(where: { $0.id == snapshotAnchorId }))
        model.tabs.remove(at: anchorIndex)
        model.promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: snapshotAnchorId)
        #expect(model.workspaceGroups.first(where: { $0.id == groupId })?.anchorWorkspaceId == a.id)

        // Accept the original confirmation. Only `a`/`b` remain in the confirmed
        // set; `a` is now the live anchor and must be closed LAST so no further
        // promotion runs. Sorting against the stale snapshot anchor would close
        // `a` first (by confirmed order) and re-promote `b`.
        groups.deleteWorkspaceGroup(confirmed: confirmation)

        let closedGroupMembers = host.closedWorkspaceIds.filter { $0 == a.id || $0 == b.id }
        #expect(closedGroupMembers == [b.id, a.id])
        #expect(host.closedWorkspaceIds.last == a.id)
        #expect(model.workspaceGroups.isEmpty)
        #expect(model.tabs.contains(where: { $0.id == outside.id }))
    }
}
