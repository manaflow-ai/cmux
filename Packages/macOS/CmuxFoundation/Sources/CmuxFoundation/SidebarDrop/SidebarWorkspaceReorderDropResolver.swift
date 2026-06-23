import CoreGraphics
import Foundation

/// Resolves sidebar workspace drag/drop hit testing into one visual and commit plan.
public struct SidebarWorkspaceReorderDropResolver: Sendable {
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
    ) -> SidebarWorkspaceReorderHitContext {
        for (index, target) in sortedTargets.enumerated() where target.frame.contains(point) {
            let height = max(target.frame.height, 1)
            let localY = point.y - target.frame.minY
            return SidebarWorkspaceReorderHitContext(
                target: target,
                previousTarget: index > 0 ? sortedTargets[index - 1] : nil,
                nextTarget: index + 1 < sortedTargets.count ? sortedTargets[index + 1] : nil,
                edge: SidebarDropPlanner().edgeForPointer(locationY: localY, targetHeight: height),
                pointerY: localY,
                targetHeight: height
            )
        }

        guard let nextIndex = sortedTargets.firstIndex(where: { point.y < $0.frame.minY }) else {
            return SidebarWorkspaceReorderHitContext(
                target: nil,
                previousTarget: sortedTargets.last,
                nextTarget: nil,
                edge: .bottom,
                pointerY: nil,
                targetHeight: nil
            )
        }
        return SidebarWorkspaceReorderHitContext(
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
        context: SidebarWorkspaceReorderHitContext,
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> UUID? {
        guard !groupByAnchorId.keys.contains(draggedWorkspace.id) else { return nil }
        guard prefersGroupScope(request: request, context: context) else {
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

    private func targetLeadingIndent(
        for request: SidebarWorkspaceReorderDropRequest,
        context: SidebarWorkspaceReorderHitContext
    ) -> CGFloat {
        if let target = context.target {
            if target.isGroupHeader {
                return context.edge == .bottom || isGroupHeaderCenterDrop(context: context) ? request.memberIndent : 0
            }
            if target.groupId != nil {
                return max(0, target.frame.minX)
            }
            if context.edge == .top,
               let previous = context.previousTarget,
               previous.groupId != nil {
                return max(0, previous.frame.minX)
            }
            return max(0, target.frame.minX)
        }
        if let previous = context.previousTarget,
           previous.groupId != nil {
            return max(0, previous.frame.minX)
        }
        return 0
    }

    private func prefersGroupScope(
        request: SidebarWorkspaceReorderDropRequest,
        context: SidebarWorkspaceReorderHitContext
    ) -> Bool {
        if isAmbiguousRootGroupBoundary(context: context) {
            return request.point.x >= sidebarHorizontalMidpoint(targets: request.targets)
        }
        return SidebarWorkspaceGroupDropIntentPolicy(memberIndent: request.memberIndent)
            .prefersGroupScope(
                pointerX: request.point.x,
                targetLeadingIndent: targetLeadingIndent(for: request, context: context)
            )
    }

    private func isAmbiguousRootGroupBoundary(context: SidebarWorkspaceReorderHitContext) -> Bool {
        if context.edge == .top,
           context.previousTarget?.groupId != nil,
           context.target?.groupId == nil {
            return true
        }
        if context.target == nil,
           context.previousTarget?.groupId != nil {
            return true
        }
        return false
    }

    private func sidebarHorizontalMidpoint(
        targets: [SidebarWorkspaceReorderDropTarget]
    ) -> CGFloat {
        let bounds = targets.reduce(CGRect.null) { partial, target in
            partial.union(target.frame)
        }
        guard !bounds.isNull, bounds.width > 0 else { return 0 }
        return bounds.minX + (bounds.width / 2)
    }

    private func isGroupHeaderCenterDrop(context: SidebarWorkspaceReorderHitContext) -> Bool {
        guard let target = context.target,
              target.isGroupHeader,
              let pointerY = context.pointerY,
              let targetHeight = context.targetHeight else {
            return false
        }
        let height = max(targetHeight, 1)
        let edgeBand = min(max(height * 0.25, 4), height * 0.4)
        let y = min(max(pointerY, 0), height)
        return y > edgeBand && y < height - edgeBand
    }

    private func groupScopedPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: SidebarWorkspaceReorderHitContext,
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

        let renderedIndicator = SidebarDropPlanner().indicator(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: targetWorkspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            legalInsertionRange: legalRange,
            pointerY: pointerY(for: targetIndicator.edge, targetHeight: context.targetHeight),
            targetHeight: context.targetHeight,
            preserveTargetEdge: true
        ) ?? targetIndicator

        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: renderedIndicator,
            indicatorScope: .group(explicitGroupId),
            action: .reorder(
                targetIndex: targetIndex,
                usesTopLevelRows: false,
                explicitGroupId: explicitGroupId
            )
        )
    }

    private func rootScopedPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: SidebarWorkspaceReorderHitContext,
        draggedWorkspace: SidebarWorkspaceReorderWorkspaceSnapshot,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupLayoutsById: [UUID: SidebarWorkspaceReorderGroupLayout]
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
        let requestedIndicator = logicalIndicator(for: rootTarget)
        let tabIds = usesTopLevelRows
            ? topLevelWorkspaceIds(workspaces: request.workspaces, groupsById: groupsById, promotingWorkspaceId: request.draggedWorkspaceId)
            : request.workspaces.map(\.id)
        let pinnedTabIds = usesTopLevelRows
            ? topLevelPinnedWorkspaceIds(
                workspaces: request.workspaces,
                workspacesById: workspacesById,
                groupsById: groupsById,
                groupByAnchorId: groupByAnchorId,
                promotingWorkspaceId: request.draggedWorkspaceId
            )
            : Set(request.workspaces.filter { $0.groupId == nil && $0.isPinned }.map(\.id))
        guard let targetIndex = SidebarDropPlanner().targetIndex(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: rootTarget.workspaceId,
            indicator: requestedIndicator,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds
        ) else {
            return nil
        }

        let plannedIndicator = SidebarDropPlanner().indicator(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: rootTarget.workspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: rootTarget.pointerY,
            targetHeight: rootTarget.targetHeight,
            preserveTargetEdge: true
        )
        let promotesGroupedWorkspace = usesTopLevelRows &&
            draggedWorkspace.groupId != nil &&
            groupByAnchorId[draggedWorkspace.id] == nil
        guard let indicator = plannedIndicator ?? (promotesGroupedWorkspace ? rootTarget.indicator ?? requestedIndicator : nil) else {
            return nil
        }

        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: renderedIndicator(planned: indicator, requested: requestedIndicator, rootTarget: rootTarget),
            indicatorScope: rootTarget.indicatorScope,
            action: .reorder(
                targetIndex: targetIndex,
                usesTopLevelRows: usesTopLevelRows,
                explicitGroupId: nil
            )
        )
    }

    private func crossWindowPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: SidebarWorkspaceReorderHitContext,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupLayoutsById: [UUID: SidebarWorkspaceReorderGroupLayout]
    ) -> SidebarWorkspaceReorderDropPlan? {
        guard let draggedIsPinned = request.foreignDraggedIsPinned else { return nil }
        let rootTarget = rootTarget(
            point: request.point,
            context: context,
            workspacesById: workspacesById,
            groupsById: groupsById,
            groupLayoutsById: groupLayoutsById
        )
        let requestedIndicator = logicalIndicator(for: rootTarget)
        let topLevelIds = topLevelWorkspaceIds(
            workspaces: request.workspaces,
            groupsById: groupsById,
            promotingWorkspaceId: nil
        )
        let proposedInsertionIndex = insertionPosition(for: requestedIndicator, tabIds: topLevelIds)
        let result = SidebarDropPlanner().crossWindowInsertion(
            targetTabId: rootTarget.workspaceId,
            draggedIsPinned: draggedIsPinned,
            indicator: nil,
            tabIds: topLevelIds,
            pinnedTabIds: topLevelPinnedWorkspaceIds(
                workspaces: request.workspaces,
                workspacesById: workspacesById,
                groupsById: groupsById,
                groupByAnchorId: groupByAnchorId,
                promotingWorkspaceId: nil
            ),
            pointerY: rootTarget.pointerY,
            targetHeight: rootTarget.targetHeight
        )
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: renderedIndicator(planned: result.indicator, requested: requestedIndicator, rootTarget: rootTarget),
            indicatorScope: rootTarget.indicatorScope,
            action: .crossWindow(
                insertionIndex: result.insertionIndex,
                proposedInsertionIndex: proposedInsertionIndex
            )
        )
    }

    private func groupScopedIndicator(
        context: SidebarWorkspaceReorderHitContext,
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
        context: SidebarWorkspaceReorderHitContext,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupLayoutsById: [UUID: SidebarWorkspaceReorderGroupLayout]
    ) -> SidebarWorkspaceReorderRootTarget {
        guard let target = context.target else {
            return SidebarWorkspaceReorderRootTarget(
                workspaceId: nil,
                edge: .bottom,
                pointerY: nil,
                targetHeight: nil,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
                indicatorScope: .topLevel
            )
        }
        if let groupId = target.groupId,
           let layout = groupLayoutsById[groupId] {
            if point.y < layout.bounds.midY {
                return SidebarWorkspaceReorderRootTarget(
                    workspaceId: layout.anchorTarget.workspaceId,
                    edge: .top,
                    pointerY: 0,
                    targetHeight: max(layout.anchorTarget.frame.height, 1),
                    indicator: SidebarDropIndicator(tabId: layout.anchorTarget.workspaceId, edge: .top),
                    indicatorScope: .topLevel
                )
            }
            if let nextRootTarget = layout.nextRootTarget {
                return SidebarWorkspaceReorderRootTarget(
                    workspaceId: nextRootTarget.workspaceId,
                    edge: .top,
                    pointerY: 0,
                    targetHeight: max(nextRootTarget.frame.height, 1),
                    indicator: SidebarDropIndicator(tabId: nextRootTarget.workspaceId, edge: .top),
                    indicatorScope: .topLevel
                )
            }
            return SidebarWorkspaceReorderRootTarget(
                workspaceId: nil,
                edge: .bottom,
                pointerY: nil,
                targetHeight: nil,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
                indicatorScope: .topLevel
            )
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
        return SidebarWorkspaceReorderRootTarget(
            workspaceId: workspaceId,
            edge: context.edge,
            pointerY: context.pointerY,
            targetHeight: context.targetHeight,
            indicator: SidebarDropIndicator(tabId: workspaceId, edge: context.edge),
            indicatorScope: groupsById.isEmpty ? .raw : .topLevel
        )
    }

    private func logicalIndicator(for rootTarget: SidebarWorkspaceReorderRootTarget) -> SidebarDropIndicator {
        rootTarget.workspaceId.map {
            SidebarDropIndicator(tabId: $0, edge: rootTarget.edge)
        } ?? SidebarDropIndicator(tabId: nil, edge: .bottom)
    }

    private func insertionPosition(for indicator: SidebarDropIndicator, tabIds: [UUID]) -> Int {
        guard let tabId = indicator.tabId,
              let index = tabIds.firstIndex(of: tabId) else {
            return tabIds.count
        }
        return indicator.edge == .bottom ? index + 1 : index
    }

    private func renderedIndicator(
        planned: SidebarDropIndicator,
        requested: SidebarDropIndicator,
        rootTarget: SidebarWorkspaceReorderRootTarget
    ) -> SidebarDropIndicator {
        guard planned == requested else { return planned }
        return rootTarget.indicator ?? planned
    }

    private func groupLayouts(
        sortedTargets: [SidebarWorkspaceReorderDropTarget],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> [UUID: SidebarWorkspaceReorderGroupLayout] {
        var boundsByGroupId: [UUID: CGRect] = [:]
        var anchorTargetByGroupId: [UUID: SidebarWorkspaceReorderDropTarget] = [:]
        var lastIndexByGroupId: [UUID: Int] = [:]
        for (index, target) in sortedTargets.enumerated() {
            guard let groupId = target.groupId,
                  let group = groupsById[groupId] else {
                continue
            }
            boundsByGroupId[groupId] = boundsByGroupId[groupId]?.union(target.frame) ?? target.frame
            lastIndexByGroupId[groupId] = index
            if target.workspaceId == group.anchorWorkspaceId {
                anchorTargetByGroupId[groupId] = target
            }
        }

        var nextRootTargetByGroupId: [UUID: SidebarWorkspaceReorderDropTarget] = [:]
        var nextRootTarget: SidebarWorkspaceReorderDropTarget?
        for index in sortedTargets.indices.reversed() {
            let target = sortedTargets[index]
            if let groupId = target.groupId,
               lastIndexByGroupId[groupId] == index {
                nextRootTargetByGroupId[groupId] = nextRootTarget
            }
            if target.groupId == nil {
                nextRootTarget = target
            }
        }

        var layouts: [UUID: SidebarWorkspaceReorderGroupLayout] = [:]
        for groupId in groupsById.keys {
            guard let bounds = boundsByGroupId[groupId],
                  let anchorTarget = anchorTargetByGroupId[groupId] else {
                continue
            }
            layouts[groupId] = SidebarWorkspaceReorderGroupLayout(
                bounds: bounds,
                anchorTarget: anchorTarget,
                nextRootTarget: nextRootTargetByGroupId[groupId]
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
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        promotingWorkspaceId: UUID?
    ) -> Set<UUID> {
        Set(topLevelWorkspaceIds(
            workspaces: workspaces,
            groupsById: groupsById,
            promotingWorkspaceId: promotingWorkspaceId
        ).filter { id in
            if let group = groupByAnchorId[id] {
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
