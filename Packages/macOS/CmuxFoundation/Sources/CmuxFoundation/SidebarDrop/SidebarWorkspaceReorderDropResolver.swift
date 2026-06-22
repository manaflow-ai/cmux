import CoreGraphics
import Foundation

/// Resolves sidebar workspace drag/drop hit testing into one visual and commit plan.
public struct SidebarWorkspaceReorderDropResolver: Sendable {
    private struct HitContext {
        let target: SidebarWorkspaceReorderDropTarget?
        let previousTarget: SidebarWorkspaceReorderDropTarget?
        let nextTarget: SidebarWorkspaceReorderDropTarget?
        let edge: SidebarDropEdge
        let pointerY: CGFloat?
        let targetHeight: CGFloat?
    }

    private struct RootTarget {
        let workspaceId: UUID?
        let edge: SidebarDropEdge
        let pointerY: CGFloat?
        let targetHeight: CGFloat?
    }

    private struct GroupLayout {
        let bounds: CGRect
        let nextRootTarget: SidebarWorkspaceReorderDropTarget?
    }

    /// Creates a sidebar workspace reorder resolver.
    public init() {}

    /// Resolves the request into the drop plan the UI should render and commit.
    ///
    /// - Parameter request: The immutable drop input snapshot.
    /// - Returns: A plan when the pointer can produce a meaningful drop.
    public func plan(
        for request: SidebarWorkspaceReorderDropRequest
    ) -> SidebarWorkspaceReorderDropPlan? {
        let sortedTargets = request.targets.sorted { lhs, rhs in
            if lhs.frame.minY == rhs.frame.minY {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }
        guard !sortedTargets.isEmpty else { return nil }

        let groupsById = Dictionary(uniqueKeysWithValues: request.groups.map { ($0.id, $0) })
        let groupByAnchorId = Dictionary(uniqueKeysWithValues: request.groups.map { ($0.anchorWorkspaceId, $0) })
        let workspacesById = Dictionary(uniqueKeysWithValues: request.workspaces.map { ($0.id, $0) })
        let groupLayoutsById = groupLayouts(
            sortedTargets: sortedTargets,
            groupsById: groupsById
        )
        let context = hitContext(point: request.point, sortedTargets: sortedTargets)

        guard let draggedWorkspace = workspacesById[request.draggedWorkspaceId] else {
            return crossWindowPlan(
                request: request,
                context: context,
                workspacesById: workspacesById,
                groupsById: groupsById,
                groupByAnchorId: groupByAnchorId,
                groupLayoutsById: groupLayoutsById
            )
        }

        if let groupId = explicitGroupId(
            request: request,
            context: context,
            draggedWorkspace: draggedWorkspace,
            groupsById: groupsById,
            groupByAnchorId: groupByAnchorId
        ) {
            return groupScopedPlan(
                request: request,
                context: context,
                draggedWorkspace: draggedWorkspace,
                explicitGroupId: groupId,
                groupsById: groupsById
            )
        }

        return rootScopedPlan(
            request: request,
            context: context,
            draggedWorkspace: draggedWorkspace,
            workspacesById: workspacesById,
            groupsById: groupsById,
            groupByAnchorId: groupByAnchorId,
            groupLayoutsById: groupLayoutsById
        )
    }

    private func hitContext(
        point: CGPoint,
        sortedTargets: [SidebarWorkspaceReorderDropTarget]
    ) -> HitContext {
        for (index, target) in sortedTargets.enumerated() where target.frame.contains(point) {
            let height = max(target.frame.height, 1)
            let localY = point.y - target.frame.minY
            return HitContext(
                target: target,
                previousTarget: index > 0 ? sortedTargets[index - 1] : nil,
                nextTarget: index + 1 < sortedTargets.count ? sortedTargets[index + 1] : nil,
                edge: SidebarDropPlanner().edgeForPointer(locationY: localY, targetHeight: height),
                pointerY: localY,
                targetHeight: height
            )
        }

        guard let nextIndex = sortedTargets.firstIndex(where: { point.y < $0.frame.minY }) else {
            return HitContext(
                target: nil,
                previousTarget: sortedTargets.last,
                nextTarget: nil,
                edge: .bottom,
                pointerY: nil,
                targetHeight: nil
            )
        }
        return HitContext(
            target: sortedTargets[nextIndex],
            previousTarget: nextIndex > 0 ? sortedTargets[nextIndex - 1] : nil,
            nextTarget: sortedTargets[nextIndex],
            edge: .top,
            pointerY: 0,
            targetHeight: max(sortedTargets[nextIndex].frame.height, 1)
        )
    }

    private func explicitGroupId(
        request: SidebarWorkspaceReorderDropRequest,
        context: HitContext,
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> UUID? {
        guard !groupByAnchorId.keys.contains(draggedWorkspace.id) else { return nil }
        guard SidebarWorkspaceGroupDropIntentPolicy(memberIndent: request.memberIndent)
            .prefersGroupScope(pointerX: request.point.x, targetLeadingIndent: request.memberIndent) else {
            return nil
        }

        if let target = context.target,
           let groupId = target.groupId,
           groupsById[groupId] != nil {
            return groupId
        }

        if context.edge == .top,
           let previousGroupId = context.previousTarget?.groupId,
           let next = context.nextTarget,
           next.groupId == nil,
           groupsById[previousGroupId] != nil {
            return previousGroupId
        }

        if context.edge == .bottom,
           let targetGroupId = context.target?.groupId,
           groupsById[targetGroupId] != nil {
            return targetGroupId
        }

        return nil
    }

    private func groupScopedPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: HitContext,
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        explicitGroupId: UUID,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let group = groupsById[explicitGroupId] else { return nil }
        let targetIndicator = groupScopedIndicator(
            context: context,
            fallbackAnchorWorkspaceId: group.anchorWorkspaceId
        )
        guard let targetWorkspaceId = targetIndicator.tabId else { return nil }
        let tabIds = request.workspaces.map(\.id)
        let pinnedTabIds = Set(request.workspaces.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        let legalRange = legalInsertionRange(
            draggedWorkspace: draggedWorkspace,
            explicitGroupId: explicitGroupId,
            workspaces: request.workspaces,
            groupsById: groupsById
        )
        guard let targetIndex = SidebarDropPlanner().targetIndex(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: targetWorkspaceId,
            indicator: targetIndicator,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalRange
        ) else {
            return nil
        }

        let isMembershipChange = draggedWorkspace.groupId != explicitGroupId
        guard targetIndex != (tabIds.firstIndex(of: request.draggedWorkspaceId) ?? targetIndex) || isMembershipChange else {
            return nil
        }

        let renderedIndicator = SidebarDropPlanner().indicator(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: targetWorkspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalRange,
            pointerY: pointerY(for: targetIndicator.edge, targetHeight: context.targetHeight),
            targetHeight: context.targetHeight,
            preserveTargetEdge: true
        ) ?? (isMembershipChange ? targetIndicator : nil)

        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: renderedIndicator,
            action: .reorder(
                targetIndex: targetIndex,
                usesTopLevelRows: false,
                explicitGroupId: explicitGroupId
            )
        )
    }

    private func rootScopedPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: HitContext,
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupLayoutsById: [UUID: GroupLayout]
    ) -> SidebarWorkspaceReorderDropPlan? {
        let usesTopLevelRows = !groupsById.isEmpty && (
            draggedWorkspace.groupId != nil ||
                groupByAnchorId[draggedWorkspace.id] != nil ||
                context.target?.groupId != nil ||
                context.previousTarget?.groupId != nil
        )
        let rootTarget = rootTarget(
            point: request.point,
            context: context,
            workspacesById: workspacesById,
            groupsById: groupsById,
            groupLayoutsById: groupLayoutsById
        )
        let tabIds = usesTopLevelRows
            ? topLevelWorkspaceIds(workspaces: request.workspaces, groupsById: groupsById, promotingWorkspaceId: request.draggedWorkspaceId)
            : request.workspaces.map(\.id)
        let pinnedTabIds = usesTopLevelRows
            ? topLevelPinnedWorkspaceIds(workspaces: request.workspaces, workspacesById: workspacesById, groupsById: groupsById)
            : Set(request.workspaces.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        guard let targetIndex = SidebarDropPlanner().targetIndex(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: rootTarget.workspaceId,
            indicator: rootTarget.workspaceId.map { SidebarDropIndicator(tabId: $0, edge: rootTarget.edge) },
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds
        ) else {
            return nil
        }

        let indicator = SidebarDropPlanner().indicator(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: rootTarget.workspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: rootTarget.pointerY,
            targetHeight: rootTarget.targetHeight,
            preserveTargetEdge: true
        )
        guard indicator != nil else { return nil }

        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: indicator,
            action: .reorder(
                targetIndex: targetIndex,
                usesTopLevelRows: usesTopLevelRows,
                explicitGroupId: nil
            )
        )
    }

    private func crossWindowPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: HitContext,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupLayoutsById: [UUID: GroupLayout]
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let draggedIsPinned = request.foreignDraggedIsPinned else { return nil }
        let rootTarget = rootTarget(
            point: request.point,
            context: context,
            workspacesById: workspacesById,
            groupsById: groupsById,
            groupLayoutsById: groupLayoutsById
        )
        let topLevelIds = topLevelWorkspaceIds(
            workspaces: request.workspaces,
            groupsById: groupsById,
            promotingWorkspaceId: nil
        )
        let result = SidebarDropPlanner().crossWindowInsertion(
            targetTabId: rootTarget.workspaceId,
            draggedIsPinned: draggedIsPinned,
            indicator: nil,
            tabIds: topLevelIds,
            pinnedTabIds: topLevelPinnedWorkspaceIds(
                workspaces: request.workspaces,
                workspacesById: workspacesById,
                groupsById: groupsById
            ),
            pointerY: rootTarget.pointerY,
            targetHeight: rootTarget.targetHeight
        )
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: result.indicator,
            action: .crossWindow(insertionIndex: result.insertionIndex)
        )
    }

    private func groupScopedIndicator(
        context: HitContext,
        fallbackAnchorWorkspaceId: UUID
    ) -> SidebarDropIndicator {
        if context.edge == .top,
           let target = context.target,
           target.groupId == nil,
           let previous = context.previousTarget,
           previous.groupId != nil {
            return SidebarDropIndicator(tabId: previous.workspaceId, edge: .bottom)
        }
        if let target = context.target {
            if target.isGroupHeader {
                return SidebarDropIndicator(tabId: target.workspaceId, edge: .bottom)
            }
            return SidebarDropIndicator(tabId: target.workspaceId, edge: context.edge)
        }
        if let previous = context.previousTarget, previous.groupId != nil {
            return SidebarDropIndicator(tabId: previous.workspaceId, edge: .bottom)
        }
        return SidebarDropIndicator(tabId: fallbackAnchorWorkspaceId, edge: .bottom)
    }

    private func rootTarget(
        point: CGPoint,
        context: HitContext,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupLayoutsById: [UUID: GroupLayout]
    ) -> RootTarget {
        guard let target = context.target else {
            return RootTarget(workspaceId: nil, edge: .bottom, pointerY: nil, targetHeight: nil)
        }
        if let groupId = target.groupId,
           let layout = groupLayoutsById[groupId],
           point.y >= layout.bounds.midY {
            if let nextRootTarget = layout.nextRootTarget {
                return RootTarget(
                    workspaceId: nextRootTarget.workspaceId,
                    edge: .top,
                    pointerY: 0,
                    targetHeight: max(nextRootTarget.frame.height, 1)
                )
            }
            return RootTarget(workspaceId: nil, edge: .bottom, pointerY: nil, targetHeight: nil)
        }
        let workspaceId: UUID
        if let groupId = target.groupId,
           let group = groupsById[groupId] {
            workspaceId = group.anchorWorkspaceId
        } else if let groupId = workspacesById[target.workspaceId]?.groupId,
                  let group = groupsById[groupId] {
            workspaceId = group.anchorWorkspaceId
        } else {
            workspaceId = target.workspaceId
        }
        return RootTarget(
            workspaceId: workspaceId,
            edge: context.edge,
            pointerY: context.pointerY,
            targetHeight: context.targetHeight
        )
    }

    private func groupLayouts(
        sortedTargets: [SidebarWorkspaceReorderDropTarget],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> [UUID: GroupLayout] {
        var layouts: [UUID: GroupLayout] = [:]
        for (groupId, group) in groupsById {
            let indices = sortedTargets.indices.filter { sortedTargets[$0].groupId == groupId }
            guard let firstIndex = indices.first,
                  let lastIndex = indices.last,
                  sortedTargets.contains(where: { $0.workspaceId == group.anchorWorkspaceId }) else {
                continue
            }
            let bounds = indices.dropFirst().reduce(sortedTargets[firstIndex].frame) { partial, index in
                partial.union(sortedTargets[index].frame)
            }
            let nextRootTarget = sortedTargets[(lastIndex + 1)...].first { $0.groupId == nil }
            layouts[groupId] = GroupLayout(
                bounds: bounds,
                nextRootTarget: nextRootTarget
            )
        }
        return layouts
    }

    private func legalInsertionRange(
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        explicitGroupId: UUID,
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> ClosedRange<Int>? {
        guard let group = groupsById[explicitGroupId],
              draggedWorkspace.id != group.anchorWorkspaceId else {
            return nil
        }
        let memberIndices = workspaces.indices.filter { workspaces[$0].groupId == explicitGroupId }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = workspaces[index]
            if member.id != group.anchorWorkspaceId, member.isPinned {
                count += 1
            }
        }
        if draggedWorkspace.isPinned {
            let lower = min(firstIndex + 1, workspaces.count)
            let upper = min(firstIndex + 1 + pinnedMemberCount, workspaces.count)
            return lower...max(lower, upper)
        }
        let lower = min(firstIndex + 1 + pinnedMemberCount, workspaces.count)
        let upper = min(lastIndex + 1, workspaces.count)
        return min(lower, upper)...max(lower, upper)
    }

    private func topLevelWorkspaceIds(
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        promotingWorkspaceId: UUID?
    ) -> [UUID] {
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            if let groupId = workspace.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(workspace.id)
            }
        }
        if let promotingWorkspaceId,
           !ids.contains(promotingWorkspaceId),
           let promoted = workspaces.first(where: { $0.id == promotingWorkspaceId }),
           let groupId = promoted.groupId,
           let group = groupsById[groupId],
           let groupIndex = ids.firstIndex(of: group.anchorWorkspaceId) {
            ids.insert(promotingWorkspaceId, at: min(groupIndex + 1, ids.count))
        }
        return ids
    }

    private func topLevelPinnedWorkspaceIds(
        workspaces: [SidebarWorkspaceReorderWorkspaceSnapshot],
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> Set<UUID> {
        Set(topLevelWorkspaceIds(
            workspaces: workspaces,
            groupsById: groupsById,
            promotingWorkspaceId: nil
        ).filter { id in
            if let group = groupsById.values.first(where: { $0.anchorWorkspaceId == id }) {
                return group.isPinned
            }
            return workspacesById[id]?.isPinned == true
        })
    }

    private func pointerY(for edge: SidebarDropEdge, targetHeight: CGFloat?) -> CGFloat? {
        guard let targetHeight else { return nil }
        return edge == .top ? 0 : targetHeight
    }
}
