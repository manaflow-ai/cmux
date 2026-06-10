import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Workspace Reordering & Pinning
extension TabManager {
    func moveTabToTop(_ tabId: UUID) {
        moveTabsToTop([tabId])
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let previousOrder = tabs.map(\.id)

        if !workspaceGroups.isEmpty {
            moveWorkspaceGroupMembersAfterAnchors(workspaceIds: selectedTabs.map(\.id))
            let topLevelIds = sidebarTopLevelWorkspaceIds()
            let selectedTopLevelIds = topLevelWorkspaceIds(for: selectedTabs)
            let selectedTopLevelIdSet = Set(selectedTopLevelIds)
            let pinnedTopLevelIds = sidebarTopLevelPinnedWorkspaceIds()
            let desiredTopLevelIds =
                selectedTopLevelIds.filter { pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) } +
                selectedTopLevelIds.filter { !pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { !pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) }
            normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            syncWorkspaceGroupsOrderToAnchorOrder()
        } else {
            let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
            let selectedPinned = selectedTabs.filter { $0.isPinned }
            let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
            let remainingPinned = remainingTabs.filter { $0.isPinned }
            let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
            tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
        }
        if tabs.map(\.id) != previousOrder {
            postWorkspaceOrderDidChange(movedWorkspaceIds: selectedTabs.map(\.id))
        }
    }

    func moveTabToTopForNotification(_ tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let previousOrder = tabs.map(\.id)

        if !workspaceGroups.isEmpty {
            guard let topLevelId = topLevelWorkspaceIds(for: [tab]).first else { return }
            let pinnedTopLevelIds = sidebarTopLevelPinnedWorkspaceIds()
            guard !pinnedTopLevelIds.contains(topLevelId) else { return }
            moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [tabId])
            var desiredTopLevelIds = sidebarTopLevelWorkspaceIds()
            guard let fromIndex = desiredTopLevelIds.firstIndex(of: topLevelId) else { return }
            let pinnedCount = desiredTopLevelIds.reduce(into: 0) { count, id in
                if pinnedTopLevelIds.contains(id) {
                    count += 1
                }
            }
            if fromIndex != pinnedCount {
                let movedId = desiredTopLevelIds.remove(at: fromIndex)
                desiredTopLevelIds.insert(movedId, at: min(pinnedCount, desiredTopLevelIds.count))
            }
            normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            syncWorkspaceGroupsOrderToAnchorOrder()
        } else {
            guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
            let pinnedCount = tabs.filter { $0.isPinned }.count
            guard index != pinnedCount else { return }
            let tab = tabs[index]
            guard !tab.isPinned else { return }
            tabs.remove(at: index)
            tabs.insert(tab, at: pinnedCount)
        }
        if tabs.map(\.id) != previousOrder {
            postWorkspaceOrderDidChange(movedWorkspaceIds: [tabId])
        }
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, toIndex targetIndex: Int, isDragOperation: Bool = false) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, toIndex: targetIndex) else { return false }
        // No-op reorders (single workspace, clamped to current index, etc.)
        // must not run group inference. Otherwise socket calls like
        // `workspace.action move_down` on the last ungrouped row would
        // silently absorb it into the group above just because the request
        // resolved to "stay put."
        if tabs.count <= 1 || plan.fromIndex == plan.toIndex {
            return true
        }

        let workspace = tabs.remove(at: plan.fromIndex)
        tabs.insert(workspace, at: plan.toIndex)
        if isDragOperation {
            applyDragInferredGroupMembership(workspaceId: tabId)
        } else if !workspaceGroups.isEmpty {
            if workspaceGroups.contains(where: { $0.anchorWorkspaceId == tabId }) {
                syncWorkspaceGroupsOrderToAnchorOrder()
            }
            normalizeWorkspaceGroupContiguity()
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tabId])
        return true
    }

    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> [UUID] {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return tabs.map(\.id)
        }
        return sidebarTopLevelWorkspaceIds(promotingWorkspaceId: draggedWorkspaceId)
    }

    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> Set<UUID> {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return Set(tabs.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        }
        return sidebarTopLevelPinnedWorkspaceIds()
    }

    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> ClosedRange<Int>? {
        guard !usesTopLevelRows,
              !sidebarReorderUsesTopLevelRows(
                  forDraggedWorkspaceId: draggedWorkspaceId,
                  targetWorkspaceId: targetWorkspaceId
              ),
              let draggedWorkspaceId,
              let draggedWorkspace = tabs.first(where: { $0.id == draggedWorkspaceId }),
              let groupId = draggedWorkspace.groupId,
              let group = workspaceGroups.first(where: { $0.id == groupId }),
              draggedWorkspace.id != group.anchorWorkspaceId else {
            return nil
        }
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = tabs[index]
            if member.id != group.anchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        if draggedWorkspace.isPinned {
            let lower = min(firstIndex + 1, tabs.count)
            let upper = min(firstIndex + 1 + pinnedMemberCount, tabs.count)
            return lower...max(lower, upper)
        }
        let lower = min(firstIndex + 1 + pinnedMemberCount, tabs.count)
        let upper = min(lastIndex + 1, tabs.count)
        return min(lower, upper)...max(lower, upper)
    }

    @discardableResult
    func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesTopLevelRows: Bool = false
    ) -> Bool {
        if usesTopLevelRows || isWorkspaceGroupAnchor(tabId) {
            return reorderTopLevelWorkspaceItem(
                tabId: tabId,
                toIndex: targetIndex,
                promotesGroupedWorkspace: usesTopLevelRows
            )
        }
        return reorderWorkspace(tabId: tabId, toIndex: targetIndex, isDragOperation: isDragOperation)
    }

    @discardableResult
    private func reorderTopLevelWorkspaceItem(
        tabId: UUID,
        toIndex targetIndex: Int,
        promotesGroupedWorkspace: Bool = false
    ) -> Bool {
        let topLevelIds = sidebarTopLevelWorkspaceIds(
            promotingWorkspaceId: promotesGroupedWorkspace ? tabId : nil
        )
        guard let fromIndex = topLevelIds.firstIndex(of: tabId) else { return false }
        let clampedTarget = clampedTopLevelReorderIndex(
            forWorkspaceId: tabId,
            targetIndex: targetIndex,
            topLevelIds: topLevelIds
        )
        guard fromIndex != clampedTarget else { return false }

        var desiredTopLevelIds = topLevelIds
        let movedId = desiredTopLevelIds.remove(at: fromIndex)
        desiredTopLevelIds.insert(movedId, at: clampedTarget)
        if promotesGroupedWorkspace,
           let tab = tabs.first(where: { $0.id == tabId }),
           tab.groupId != nil,
           !isWorkspaceGroupAnchor(tabId) {
            assignGroup(workspaceId: tabId, groupId: nil)
        }
        normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
        syncWorkspaceGroupsOrderToAnchorOrder()

        let movedWorkspaceIds: [UUID]
        if let group = workspaceGroups.first(where: { $0.anchorWorkspaceId == tabId }) {
            movedWorkspaceIds = tabs.filter { $0.groupId == group.id }.map(\.id)
        } else {
            movedWorkspaceIds = [tabId]
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return true
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        guard let draggedWorkspaceId else { return false }
        return isWorkspaceGroupAnchor(draggedWorkspaceId)
            || targetWorkspaceId.map(isWorkspaceGroupAnchor) == true
    }

    /// After a drag-driven reorder, infer the dragged workspace's group
    /// membership from its new neighbors in `tabs[]`:
    /// - If both neighbors share a non-nil groupId, join that group.
    /// - If only one neighbor is in a group, join that neighbor's group when
    ///   that group's anchor is the neighbor or another existing member
    ///   (i.e. the dragged workspace sits "inside" the section).
    /// - Otherwise, clear groupId.
    /// Pinned workspaces may join a group when the same neighbor-based rules
    /// place them inside that group's section.
    /// Anchors keep their group: their lifecycle is gated by group existence.
    private func applyDragInferredGroupMembership(workspaceId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let tab = tabs[index]
        let isAnchor = workspaceGroups.contains(where: { $0.anchorWorkspaceId == workspaceId })
        if isAnchor {
            // Anchors don't change group membership via drag (their group
            // identity owns them), but moving an anchor in `tabs[]` IS how
            // the user reorders the whole group. Resync `workspaceGroups`
            // order to the new anchor positions in tabs[] before normalize
            // rebuilds the section list.
            syncWorkspaceGroupsOrderToAnchorOrder()
            normalizeWorkspaceGroupContiguity()
            return
        }
        let before: Workspace? = index > 0 ? tabs[index - 1] : nil
        let after: Workspace? = (index + 1) < tabs.count ? tabs[index + 1] : nil
        let beforeGroup = before?.groupId
        let afterGroup = after?.groupId
        let currentGroup = tab.groupId
        // Three cases:
        //  A. Both neighbors share the same value (incl. both nil): land in
        //     that membership state. Sandwiched inside a group → join it.
        //     Sandwiched in the ungrouped section → clear membership.
        //  B. Otherwise (one neighbor differs from the other) — preserve
        //     current membership. This is the ambiguous edge case: dragging
        //     to the LAST slot of currentGroup and the FIRST slot just
        //     beyond currentGroup look identical via neighbor inspection,
        //     so we bias toward "user is reordering within their group"
        //     since `normalizeWorkspaceGroupContiguity()` will keep the
        //     row in the group's contiguous section anyway. To drag a
        //     workspace out of its group, the user must drop it with BOTH
        //     neighbors outside the group (case A with
        //     `beforeGroup == afterGroup != currentGroup`) or use the
        //     right-click → Remove From Group action.
        let inferred: UUID?
        if beforeGroup == afterGroup {
            inferred = beforeGroup
        } else {
            inferred = currentGroup
        }
        if tab.groupId != inferred {
            tab.groupId = inferred
            // Renormalize after group change to keep tiers contiguous.
            normalizeWorkspaceGroupContiguity()
        } else if inferred != nil {
            // Same-group drag: membership unchanged, but the drop may have
            // placed a non-anchor before the anchor in tabs[]. Renormalize
            // so the anchor stays at the section's leading edge (matches
            // the visible header position).
            normalizeWorkspaceGroupContiguity()
        }
    }

    func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if tabs.count <= 1 {
            return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: currentIndex)
        }

        let workspace = tabs[currentIndex]
        let clamped = clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: clamped)
    }

    func postWorkspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
        guard !movedWorkspaceIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: .workspaceOrderDidChange,
            object: self,
            userInfo: [WorkspaceOrderChangeNotificationKey.movedWorkspaceIds: movedWorkspaceIds]
        )
        CmuxEventBus.shared.publishWorkspaceReordered(
            workspaceIds: tabs.map(\.id),
            movedWorkspaceIds: movedWorkspaceIds,
            pinnedWorkspaceIds: tabs.filter(\.isPinned).map(\.id),
            source: "workspace.lifecycle"
        )
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil, isDragOperation: Bool = false) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: plan.toIndex, isDragOperation: isDragOperation)
    }

    func workspaceReorderPlan(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> WorkspaceReorderPlanItem? {
        guard tabs.contains(where: { $0.id == tabId }) else { return nil }
        if let beforeId {
            guard let idx = tabs.firstIndex(where: { $0.id == beforeId }) else { return nil }
            return workspaceReorderPlan(tabId: tabId, toIndex: idx)
        }
        if let afterId {
            guard let idx = tabs.firstIndex(where: { $0.id == afterId }) else { return nil }
            return workspaceReorderPlan(tabId: tabId, toIndex: idx + 1)
        }
        return nil
    }

    func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        var seen = Set<UUID>()
        for workspaceId in orderedWorkspaceIds {
            guard seen.insert(workspaceId).inserted else {
                return .failure(.duplicateWorkspace(workspaceId))
            }
        }

        let currentIndexes = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
        for workspaceId in orderedWorkspaceIds where currentIndexes[workspaceId] == nil {
            return .failure(.workspaceNotFound(workspaceId))
        }

        let finalIds = batchWorkspaceReorderFinalIds(orderedWorkspaceIds: orderedWorkspaceIds)
        let finalIndexes = Dictionary(uniqueKeysWithValues: finalIds.enumerated().map { ($0.element, $0.offset) })

        let plan = orderedWorkspaceIds.map { workspaceId in
            WorkspaceReorderPlanItem(
                workspaceId: workspaceId,
                fromIndex: currentIndexes[workspaceId] ?? 0,
                toIndex: finalIndexes[workspaceId] ?? 0
            )
        }
        return .success(plan)
    }

    @discardableResult
    func reorderWorkspaces(
        orderedWorkspaceIds: [UUID],
        dryRun: Bool = false
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        let result = workspaceBatchReorderPlan(orderedWorkspaceIds: orderedWorkspaceIds)
        guard case .success(let plan) = result else { return result }
        guard !dryRun else { return result }

        let movedWorkspaceIds = plan
            .filter { $0.fromIndex != $0.toIndex }
            .map(\.workspaceId)
        guard !movedWorkspaceIds.isEmpty else { return result }

        let workspacesById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let finalIds = batchWorkspaceReorderFinalIds(orderedWorkspaceIds: orderedWorkspaceIds)
        tabs = finalIds.compactMap { workspacesById[$0] }
        // Batch reorder rebuilds tabs from scratch, ignoring group section
        // ordering — that can split a group across the array or land a
        // non-anchor in front of its anchor. Renormalize so the contiguous
        // section + anchor-first invariants hold for socket
        // workspace.reorder_many / `cmux reorder-workspaces`.
        if !workspaceGroups.isEmpty {
            // Resync workspaceGroups order to wherever the anchors landed
            // in the rebuilt tabs[] so later group-slot moves use the same
            // order the user sees.
            syncWorkspaceGroupsOrderToAnchorOrder()
            normalizeWorkspaceGroupContiguity()
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return result
    }

    private func batchWorkspaceReorderFinalIds(orderedWorkspaceIds: [UUID]) -> [UUID] {
        let orderedSet = Set(orderedWorkspaceIds)
        let workspacesById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let orderedPinnedIds = orderedWorkspaceIds.filter { workspacesById[$0]?.isPinned == true }
        let orderedUnpinnedIds = orderedWorkspaceIds.filter { workspacesById[$0]?.isPinned == false }
        let remainingPinnedIds = tabs
            .map(\.id)
            .filter { !orderedSet.contains($0) && workspacesById[$0]?.isPinned == true }
        let remainingUnpinnedIds = tabs
            .map(\.id)
            .filter { !orderedSet.contains($0) && workspacesById[$0]?.isPinned == false }
        return orderedPinnedIds + remainingPinnedIds + orderedUnpinnedIds + remainingUnpinnedIds
    }

    func togglePin(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
        postWorkspaceOrderDidChange(movedWorkspaceIds: [tab.id])
    }

    @discardableResult
    func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        guard !workspaceIds.isEmpty else { return [] }
        if workspaceIds.count == 1,
           let workspaceId = workspaceIds.first,
           let tab = tabs.first(where: { $0.id == workspaceId }) {
            let changed = tab.isPinned != pinned
            setPinned(tab, pinned: pinned)
            return changed ? [workspaceId] : []
        }

        var seen = Set<UUID>()
        let orderedTargetIds = workspaceIds.filter { seen.insert($0).inserted }
        let targetIds = Set(orderedTargetIds)
        var workspacesById: [UUID: Workspace] = [:]
        var changedIdSet = Set<UUID>()

        for workspace in tabs {
            workspacesById[workspace.id] = workspace
            guard targetIds.contains(workspace.id), workspace.isPinned != pinned else { continue }
            workspace.isPinned = pinned
            changedIdSet.insert(workspace.id)
        }

        guard !changedIdSet.isEmpty else { return [] }
        let changedIds = orderedTargetIds.filter { changedIdSet.contains($0) }

        if !workspaceGroups.isEmpty {
            for id in changedIds {
                if let workspace = workspacesById[id] {
                    reorderTabForPinnedState(workspace)
                }
            }
            postWorkspaceOrderDidChange(movedWorkspaceIds: changedIds)
            return changedIds
        }

        let changedWorkspaces: [Workspace]
        if pinned {
            changedWorkspaces = changedIds.compactMap { workspacesById[$0] }
        } else {
            // Keep parity with reorderTabForPinnedState: each unpinned item
            // is inserted at the front of the unpinned segment, so rebuilding a
            // batch in one pass must reverse the changed input order.
            changedWorkspaces = changedIds.reversed().compactMap { workspacesById[$0] }
        }
        let remainingPinned = tabs.filter { $0.isPinned && !changedIdSet.contains($0.id) }
        let remainingUnpinned = tabs.filter { !$0.isPinned && !changedIdSet.contains($0.id) }
        tabs = remainingPinned + changedWorkspaces + remainingUnpinned
        postWorkspaceOrderDidChange(movedWorkspaceIds: changedIds)
        return changedIds
    }

    private func reorderTabForPinnedState(_ tab: Workspace) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.groupId != nil {
            normalizeWorkspaceGroupContiguity()
            return
        }
        tabs.remove(at: index)
        let pinnedCount = leadingGlobalPinnedRowCount()
        let insertIndex = min(pinnedCount, tabs.count)
        tabs.insert(tab, at: insertIndex)
    }

    // MARK: - Workspace Groups

}
