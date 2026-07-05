public import Foundation

/// Sequences every sidebar/socket workspace reorder flow over the window's
/// `WorkspacesModel`: move-to-top, single and batch reorders, drag-driven
/// group-membership inference, top-level (group-row) reorders, and pin-state
/// changes — lifted one-for-one from the legacy TabManager method bodies.
/// Pure plan computation stays in `WorkspaceReorderPlanner`; observable
/// order-change publication inverts through `WorkspaceOrderHosting`.
@MainActor
public final class WorkspaceReorderCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private let planner = WorkspaceReorderPlanner()
    private weak var host: (any WorkspaceOrderHosting)?

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    /// Attaches the window-side host for order-change publication.
    public func attach(host: any WorkspaceOrderHosting) {
        self.host = host
    }

    // MARK: - Move to top

    /// Moves one workspace to the top of its pin tier.
    public func moveTabToTop(_ tabId: UUID) {
        moveTabsToTop([tabId])
    }

    /// Moves the given workspaces to the top of their pin tiers, preserving
    /// their relative order (group members hoist behind their anchors).
    public func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = model.tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let previousOrder = model.tabs.map(\.id)

        if !model.workspaceGroups.isEmpty {
            model.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: selectedTabs.map(\.id))
            let topLevelIds = model.sidebarTopLevelWorkspaceIds()
            let selectedTopLevelIds = model.topLevelWorkspaceIds(for: selectedTabs)
            let selectedTopLevelIdSet = Set(selectedTopLevelIds)
            let pinnedTopLevelIds = model.sidebarTopLevelPinnedWorkspaceIds()
            let desiredTopLevelIds =
                selectedTopLevelIds.filter { pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) } +
                selectedTopLevelIds.filter { !pinnedTopLevelIds.contains($0) } +
                topLevelIds.filter { !pinnedTopLevelIds.contains($0) && !selectedTopLevelIdSet.contains($0) }
            model.normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            model.syncWorkspaceGroupsOrderToAnchorOrder()
        } else {
            let remainingTabs = model.tabs.filter { !tabIds.contains($0.id) }
            let selectedPinned = selectedTabs.filter { $0.isPinned }
            let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
            let remainingPinned = remainingTabs.filter { $0.isPinned }
            let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
            model.tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
        }
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: selectedTabs.map(\.id))
        }
    }

    /// Moves a workspace to the top of the unpinned tier for a notification
    /// bump; no-ops for pinned rows or rows already at the boundary.
    public func moveTabToTopForNotification(_ tabId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == tabId }) else { return }
        let previousOrder = model.tabs.map(\.id)

        if !model.workspaceGroups.isEmpty {
            guard let topLevelId = model.topLevelWorkspaceIds(for: [tab]).first else { return }
            let pinnedTopLevelIds = model.sidebarTopLevelPinnedWorkspaceIds()
            guard !pinnedTopLevelIds.contains(topLevelId) else { return }
            model.moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [tabId])
            var desiredTopLevelIds = model.sidebarTopLevelWorkspaceIds()
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
            model.normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
            model.syncWorkspaceGroupsOrderToAnchorOrder()
        } else {
            guard let index = model.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            let pinnedCount = model.tabs.filter { $0.isPinned }.count
            guard index != pinnedCount else { return }
            let tab = model.tabs[index]
            guard !tab.isPinned else { return }
            model.tabs.remove(at: index)
            model.tabs.insert(tab, at: pinnedCount)
        }
        if model.tabs.map(\.id) != previousOrder {
            host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
        }
    }

    // MARK: - Single reorder

    /// Reorders one workspace to the clamped target index; drag operations
    /// additionally run neighbor-based group-membership inference.
    @discardableResult
    public func reorderWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        explicitGroupId: UUID? = nil
    ) -> Bool {
        if let explicitGroupId,
           !model.workspaceGroups.contains(where: { $0.id == explicitGroupId }) {
            return false
        }
        let plan: WorkspaceReorderPlanItem?
        if isDragOperation, explicitGroupId != nil {
            plan = explicitGroupWorkspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        } else {
            plan = workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        }
        guard let plan else { return false }
        // No-op reorders (single workspace, clamped to current index, etc.)
        // must not run group inference. Otherwise socket calls like
        // `workspace.action move_down` on the last ungrouped row would
        // silently absorb it into the group above just because the request
        // resolved to "stay put."
        if model.tabs.count <= 1 {
            return true
        }
        if plan.fromIndex == plan.toIndex {
            guard isDragOperation, explicitGroupId != nil else {
                return true
            }
            let previousOrder = model.tabs.map(\.id)
            let previousGroupId = model.tabs[plan.fromIndex].groupId
            applyDragInferredGroupMembership(workspaceId: tabId, explicitGroupId: explicitGroupId)
            let currentGroupId = model.tabs.first(where: { $0.id == tabId })?.groupId
            if currentGroupId != previousGroupId || model.tabs.map(\.id) != previousOrder {
                host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
            }
            return true
        }

        let workspace = model.tabs.remove(at: plan.fromIndex)
        model.tabs.insert(workspace, at: plan.toIndex)
        if isDragOperation {
            applyDragInferredGroupMembership(workspaceId: tabId, explicitGroupId: explicitGroupId)
        } else if !model.workspaceGroups.isEmpty {
            if model.workspaceGroups.contains(where: { $0.anchorWorkspaceId == tabId }) {
                model.syncWorkspaceGroupsOrderToAnchorOrder()
            }
            model.normalizeWorkspaceGroupContiguity()
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: [tabId])
        return true
    }

    /// Reorders relative to a sibling workspace (socket before/after verbs).
    @discardableResult
    public func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil, isDragOperation: Bool = false) -> Bool {
        guard let plan = workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId) else { return false }
        return reorderWorkspace(tabId: tabId, toIndex: plan.toIndex, isDragOperation: isDragOperation)
    }

    /// Explicit group drops are planned by the sidebar in the intended target
    /// group's row-space. Preserve that slot here instead of reclamping against
    /// the dragged workspace's current group or global pin tier.
    private func explicitGroupWorkspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if model.tabs.count <= 1 {
            return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: currentIndex)
        }
        let clamped = max(0, min(targetIndex, model.tabs.count - 1))
        return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: clamped)
    }

    /// The clamped single-workspace reorder plan, or `nil` when unknown.
    public func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if model.tabs.count <= 1 {
            return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: currentIndex)
        }
        let workspace = model.tabs[currentIndex]
        let clamped = model.clampedReorderIndex(for: workspace, targetIndex: targetIndex)
        return WorkspaceReorderPlanItem(workspaceId: tabId, fromIndex: currentIndex, toIndex: clamped)
    }

    /// The before/after-relative reorder plan, or `nil` when unknown.
    public func workspaceReorderPlan(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> WorkspaceReorderPlanItem? {
        guard let currentIndex = model.tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        if let beforeId {
            guard let idx = model.tabs.firstIndex(where: { $0.id == beforeId }) else { return nil }
            let targetIndex = currentIndex < idx ? idx - 1 : idx
            return workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        }
        if let afterId {
            guard let idx = model.tabs.firstIndex(where: { $0.id == afterId }) else { return nil }
            let targetIndex = currentIndex < idx ? idx : idx + 1
            return workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        }
        return nil
    }

    // MARK: - Sidebar drag planning

    /// The row-id space a sidebar drag plans in (full rows, or top-level
    /// rows when the drag involves group rows or promotion).
    public func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> [UUID] {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return model.tabs.map(\.id)
        }
        return model.sidebarTopLevelWorkspaceIds(promotingWorkspaceId: draggedWorkspaceId)
    }

    /// The pinned subset of the drag's row-id space.
    public func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> Set<UUID> {
        guard usesTopLevelRows || sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) else {
            return Set(model.tabs.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        }
        return model.sidebarTopLevelPinnedWorkspaceIds(promotingWorkspaceId: draggedWorkspaceId)
    }

    /// The legal insertion range for an in-group member drag, or `nil` when
    /// the drag is not constrained to a group section.
    public func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false,
        explicitGroupId: UUID? = nil
    ) -> ClosedRange<Int>? {
        guard !usesTopLevelRows,
              (explicitGroupId != nil || !sidebarReorderUsesTopLevelRows(
                  forDraggedWorkspaceId: draggedWorkspaceId,
                  targetWorkspaceId: targetWorkspaceId
              )),
              let draggedWorkspaceId,
              let draggedWorkspace = model.tabs.first(where: { $0.id == draggedWorkspaceId }),
              let groupId = explicitGroupId ?? draggedWorkspace.groupId,
              let group = model.workspaceGroups.first(where: { $0.id == groupId }),
              draggedWorkspace.id != group.anchorWorkspaceId else {
            return nil
        }
        let memberIndices = model.tabs.indices.filter { model.tabs[$0].groupId == groupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = model.tabs[index]
            if member.id != group.anchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        if draggedWorkspace.isPinned {
            let lower = min(firstIndex + 1, model.tabs.count)
            let upper = min(firstIndex + 1 + pinnedMemberCount, model.tabs.count)
            return lower...max(lower, upper)
        }
        let lower = min(firstIndex + 1 + pinnedMemberCount, model.tabs.count)
        let upper = min(lastIndex + 1, model.tabs.count)
        return min(lower, upper)...max(lower, upper)
    }

    /// Routes a sidebar reorder to the top-level (group-row) path or the
    /// full-row path.
    @discardableResult
    public func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesTopLevelRows: Bool = false,
        explicitGroupId: UUID? = nil
    ) -> Bool {
        if usesTopLevelRows || model.isWorkspaceGroupAnchor(tabId) {
            return reorderTopLevelWorkspaceItem(
                tabId: tabId,
                toIndex: targetIndex,
                promotesGroupedWorkspace: usesTopLevelRows
            )
        }
        return reorderWorkspace(
            tabId: tabId,
            toIndex: targetIndex,
            isDragOperation: isDragOperation,
            explicitGroupId: explicitGroupId
        )
    }

    @discardableResult
    private func reorderTopLevelWorkspaceItem(
        tabId: UUID,
        toIndex targetIndex: Int,
        promotesGroupedWorkspace: Bool = false
    ) -> Bool {
        let topLevelIds = model.sidebarTopLevelWorkspaceIds(
            promotingWorkspaceId: promotesGroupedWorkspace ? tabId : nil
        )
        guard let fromIndex = topLevelIds.firstIndex(of: tabId) else { return false }
        let clampedTarget = model.clampedTopLevelReorderIndex(
            forWorkspaceId: tabId,
            targetIndex: targetIndex,
            topLevelIds: topLevelIds,
            promotingWorkspaceId: promotesGroupedWorkspace ? tabId : nil
        )
        let shouldPromoteGroupedWorkspace: Bool = {
            guard promotesGroupedWorkspace,
                  let tab = model.tabs.first(where: { $0.id == tabId }),
                  tab.groupId != nil,
                  !model.isWorkspaceGroupAnchor(tabId) else {
                return false
            }
            return true
        }()
        guard fromIndex != clampedTarget || shouldPromoteGroupedWorkspace else { return false }

        var desiredTopLevelIds = topLevelIds
        if fromIndex != clampedTarget {
            let movedId = desiredTopLevelIds.remove(at: fromIndex)
            desiredTopLevelIds.insert(movedId, at: clampedTarget)
        }
        if shouldPromoteGroupedWorkspace {
            model.assignGroup(workspaceId: tabId, groupId: nil)
        }
        model.normalizeWorkspaceGroupRunsPreservingOrder(desiredTopLevelIds)
        model.syncWorkspaceGroupsOrderToAnchorOrder()

        let movedWorkspaceIds: [UUID]
        if let group = model.workspaceGroups.first(where: { $0.anchorWorkspaceId == tabId }) {
            movedWorkspaceIds = model.tabs.filter { $0.groupId == group.id }.map(\.id)
        } else {
            movedWorkspaceIds = [tabId]
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return true
    }

    /// Whether a sidebar drag plans in top-level rows (group rows involved
    /// or a grouped child being promoted out of its group).
    public func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            workspaceGroupIdByWorkspaceId: Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.groupId) })
        )
    }

    /// Snapshot variant of `sidebarReorderUsesTopLevelRows` over a caller-
    /// provided membership map.
    public func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool {
        guard let draggedWorkspaceId else { return false }
        if model.isWorkspaceGroupAnchor(draggedWorkspaceId) ||
            targetWorkspaceId.map(model.isWorkspaceGroupAnchor) == true {
            return true
        }
        guard let draggedWorkspaceGroupId = workspaceGroupIdByWorkspaceId[draggedWorkspaceId],
              draggedWorkspaceGroupId != nil else {
            return false
        }
        // A grouped child dragged over top-level space is leaving the group;
        // plan in top-level rows so the promotion is explicit and ordered.
        guard let targetWorkspaceId else { return true }
        guard let targetWorkspaceGroupId = workspaceGroupIdByWorkspaceId[targetWorkspaceId] else {
            return false
        }
        return targetWorkspaceGroupId == nil
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
    private func applyDragInferredGroupMembership(workspaceId: UUID, explicitGroupId: UUID? = nil) {
        guard let index = model.tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let tab = model.tabs[index]
        let isAnchor = model.workspaceGroups.contains(where: { $0.anchorWorkspaceId == workspaceId })
        if isAnchor {
            // Anchors don't change group membership via drag (their group
            // identity owns them), but moving an anchor in `tabs[]` IS how
            // the user reorders the whole group. Resync `workspaceGroups`
            // order to the new anchor positions in tabs[] before normalize
            // rebuilds the section list.
            model.syncWorkspaceGroupsOrderToAnchorOrder()
            model.normalizeWorkspaceGroupContiguity()
            return
        }
        if let explicitGroupId {
            guard model.workspaceGroups.contains(where: { $0.id == explicitGroupId }) else { return }
            model.assignGroup(workspaceId: workspaceId, groupId: explicitGroupId)
            model.normalizeWorkspaceGroupContiguity()
            return
        }
        let before: Tab? = index > 0 ? model.tabs[index - 1] : nil
        let after: Tab? = (index + 1) < model.tabs.count ? model.tabs[index + 1] : nil
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
            model.assignGroup(workspaceId: workspaceId, groupId: inferred)
            // Renormalize after group change to keep tiers contiguous.
            model.normalizeWorkspaceGroupContiguity()
        } else if inferred != nil {
            // Same-group drag: membership unchanged, but the drop may have
            // placed a non-anchor before the anchor in tabs[]. Renormalize
            // so the anchor stays at the section's leading edge (matches
            // the visible header position).
            model.normalizeWorkspaceGroupContiguity()
        }
    }

    // MARK: - Batch reorder

    /// Validates a batch reorder request against the live order.
    public func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        planner.batchReorderPlan(
            orderedWorkspaceIds: orderedWorkspaceIds,
            current: workspaceOrderSnapshots()
        )
    }

    /// Applies (or dry-runs) a batch reorder, rebuilding `tabs[]` from the
    /// planner's final order and renormalizing group sections.
    @discardableResult
    public func reorderWorkspaces(
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

        let workspacesById = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0) })
        let finalIds = batchWorkspaceReorderFinalIds(orderedWorkspaceIds: orderedWorkspaceIds)
        model.tabs = finalIds.compactMap { workspacesById[$0] }
        // Batch reorder rebuilds tabs from scratch, ignoring group section
        // ordering — that can split a group across the array or land a
        // non-anchor in front of its anchor. Renormalize so the contiguous
        // section + anchor-first invariants hold for socket
        // workspace.reorder_many / `cmux reorder-workspaces`.
        if !model.workspaceGroups.isEmpty {
            // Resync workspaceGroups order to wherever the anchors landed
            // in the rebuilt tabs[] so later group-slot moves use the same
            // order the user sees.
            model.syncWorkspaceGroupsOrderToAnchorOrder()
            model.normalizeWorkspaceGroupContiguity()
        }
        host?.workspaceOrderDidChange(movedWorkspaceIds: movedWorkspaceIds)
        return result
    }

    private func batchWorkspaceReorderFinalIds(orderedWorkspaceIds: [UUID]) -> [UUID] {
        planner.batchReorderFinalIds(
            orderedWorkspaceIds: orderedWorkspaceIds,
            current: workspaceOrderSnapshots()
        )
    }

    private func workspaceOrderSnapshots() -> [WorkspaceOrderSnapshot] {
        model.tabs.map { WorkspaceOrderSnapshot(id: $0.id, isPinned: $0.isPinned) }
    }

    // MARK: - Pinning

    /// Toggles the workspace's pin state.
    public func togglePin(tabId: UUID) {
        guard let index = model.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = model.tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    /// Sets one workspace's pin state and reorders it into its tier.
    public func setPinned(_ tab: Tab, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
        host?.workspaceOrderDidChange(movedWorkspaceIds: [tab.id])
    }

    /// Sets pin state for many workspaces at once; returns the ids whose
    /// state actually changed, in request order.
    @discardableResult
    public func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        guard !workspaceIds.isEmpty else { return [] }
        if workspaceIds.count == 1,
           let workspaceId = workspaceIds.first,
           let tab = model.tabs.first(where: { $0.id == workspaceId }) {
            let changed = tab.isPinned != pinned
            setPinned(tab, pinned: pinned)
            return changed ? [workspaceId] : []
        }

        var seen = Set<UUID>()
        let orderedTargetIds = workspaceIds.filter { seen.insert($0).inserted }
        let targetIds = Set(orderedTargetIds)
        var workspacesById: [UUID: Tab] = [:]
        var changedIdSet = Set<UUID>()

        for workspace in model.tabs {
            workspacesById[workspace.id] = workspace
            guard targetIds.contains(workspace.id), workspace.isPinned != pinned else { continue }
            workspace.isPinned = pinned
            changedIdSet.insert(workspace.id)
        }

        guard !changedIdSet.isEmpty else { return [] }
        let changedIds = orderedTargetIds.filter { changedIdSet.contains($0) }

        if !model.workspaceGroups.isEmpty {
            for id in changedIds {
                if let workspace = workspacesById[id] {
                    reorderTabForPinnedState(workspace)
                }
            }
            host?.workspaceOrderDidChange(movedWorkspaceIds: changedIds)
            return changedIds
        }

        let changedWorkspaces: [Tab]
        if pinned {
            changedWorkspaces = changedIds.compactMap { workspacesById[$0] }
        } else {
            // Keep parity with reorderTabForPinnedState: each unpinned item
            // is inserted at the front of the unpinned segment, so rebuilding a
            // batch in one pass must reverse the changed input order.
            changedWorkspaces = changedIds.reversed().compactMap { workspacesById[$0] }
        }
        let remainingPinned = model.tabs.filter { $0.isPinned && !changedIdSet.contains($0.id) }
        let remainingUnpinned = model.tabs.filter { !$0.isPinned && !changedIdSet.contains($0.id) }
        model.tabs = remainingPinned + changedWorkspaces + remainingUnpinned
        host?.workspaceOrderDidChange(movedWorkspaceIds: changedIds)
        return changedIds
    }

    private func reorderTabForPinnedState(_ tab: Tab) {
        guard let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.groupId != nil {
            model.normalizeWorkspaceGroupContiguity()
            return
        }
        model.tabs.remove(at: index)
        let pinnedCount = model.leadingGlobalPinnedRowCount()
        let insertIndex = min(pinnedCount, model.tabs.count)
        model.tabs.insert(tab, at: insertIndex)
    }
}
