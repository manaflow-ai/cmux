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
            if let draggedGroup = groupsById[request.draggedWorkspaceId], draggedGroup.isEmpty {
                return emptyGroupHeaderPlan(
                    request: request,
                    context: context,
                    draggedGroup: draggedGroup,
                    groupsById: groupsById,
                    sortedTargets: sortedTargets
                )
            }
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

    private func emptyGroupHeaderPlan(
        request: SidebarWorkspaceReorderDropRequest,
        context: SidebarWorkspaceReorderHitContext,
        draggedGroup: SidebarWorkspaceReorderGroupSnapshot,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        sortedTargets: [SidebarWorkspaceReorderDropTarget]
    ) -> SidebarWorkspaceReorderDropPlan {
        let groupOrder = request.groups.map(\.id)
        let currentIndex = groupOrder.firstIndex(of: draggedGroup.id) ?? groupOrder.count
        let targetGroupId: UUID? = {
            guard let target = context.target else { return nil }
            if let groupId = target.groupId, groupId != draggedGroup.id {
                return groupId
            }
            if let previousGroupId = context.previousTarget?.groupId,
               previousGroupId != draggedGroup.id,
               groupsById[previousGroupId] != nil {
                return previousGroupId
            }
            return nil
        }()
        let rawTargetIndex: Int = {
            if let targetGroupId,
               let targetGroupIndex = groupOrder.firstIndex(of: targetGroupId) {
                return targetGroupIndex + (context.edge == .bottom ? 1 : 0)
            }
            // For a root workspace target, count group headers above the
            // pointer. This keeps the group-slot target independent of raw tab
            // membership, which is absent for a header-only group.
            let headerCountBeforePointer = sortedTargets.filter { target in
                target.isGroupHeader && target.frame.maxY <= request.point.y
            }.count
            return context.edge == .top
                ? headerCountBeforePointer
                : headerCountBeforePointer
        }()
        // `moveWorkspaceGroup` receives the final index after removing the
        // source. Translate the pointer slot from the full group order so a
        // source above the target does not land one slot too far right.
        let adjustedTargetIndex = currentIndex < rawTargetIndex
            ? rawTargetIndex - 1
            : rawTargetIndex
        let clampedTargetIndex = max(0, min(adjustedTargetIndex, groupOrder.count - 1))
        let indicator: SidebarDropIndicator = {
            guard let target = context.target else {
                return SidebarDropIndicator(tabId: nil, edge: .bottom)
            }
            let targetId = target.groupId
                .flatMap { groupsById[$0]?.anchorWorkspaceId }
                ?? target.workspaceId
            return SidebarDropIndicator(tabId: targetId, edge: context.edge)
        }()
        // Keep the source id in the plan as the stable empty-header identity;
        // the commit layer interprets the explicit group action, never a
        // workspace lookup.
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: draggedGroup.id,
            indicator: indicator,
            indicatorScope: .topLevel,
            action: .reorderGroup(targetIndex: clampedTargetIndex)
        )
    }

    private func hitContext(
        point: CGPoint,
        sortedTargets: [SidebarWorkspaceReorderDropTarget]
    ) -> SidebarWorkspaceReorderHitContext {
        for (index, target) in sortedTargets.enumerated() where target.frame.verticallyContains(point.y) {
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
        if nextIndex > 0 {
            let previousIndex = nextIndex - 1
            let previousTarget = sortedTargets[previousIndex]
            let nextTarget = sortedTargets[nextIndex]
            let previousDistance = max(0, point.y - previousTarget.frame.maxY)
            let nextDistance = max(0, nextTarget.frame.minY - point.y)
            if previousDistance < nextDistance {
                let previousHeight = max(previousTarget.frame.height, 1)
                return SidebarWorkspaceReorderHitContext(
                    target: previousTarget,
                    previousTarget: previousIndex > 0 ? sortedTargets[previousIndex - 1] : nil,
                    nextTarget: nextTarget,
                    edge: .bottom,
                    pointerY: previousHeight,
                    targetHeight: previousHeight
                )
            }
        }
        return SidebarWorkspaceReorderHitContext(
            target: sortedTargets[nextIndex],
            previousTarget: nextIndex > 0 ? sortedTargets[nextIndex - 1] : nil,
            nextTarget: nextIndex + 1 < sortedTargets.count ? sortedTargets[nextIndex + 1] : nil,
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
        guard let candidate = groupScopeCandidate(
            context: context,
            groupsById: groupsById
        ) else {
            return nil
        }
        guard candidate.isAmbiguous else { return candidate.groupId }
        // Ambiguous group/root dividers use a coarse hierarchy lane: the left
        // half of the sidebar means root, the right half means the group.
        return request.point.x >= sidebarHorizontalMidpoint(targets: request.targets)
            ? candidate.groupId
            : nil
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

    private func groupScopeCandidate(
        context: SidebarWorkspaceReorderHitContext,
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> (groupId: UUID, isAmbiguous: Bool)? {
        if let target = context.target {
            if let groupId = target.groupId,
               groupsById[groupId] != nil {
                switch context.edge {
                case .top:
                    guard !target.isGroupHeader else { return nil }
                    return (groupId, false)
                case .bottom:
                    // A group header's lower half is the group's own adopt
                    // zone, so hovering it plans a drop *into* the group
                    // whether or not the group's rows are visible underneath.
                    // A collapsed group (and one whose only member is its
                    // anchor) has no member row below the header, and reading
                    // that as a group/root boundary sent the drop through the
                    // horizontal lane rule below — where the left half planned
                    // a root slot beside the group and the group looked
                    // undroppable, because the gap that would have accepted the
                    // workspace is exactly the one the collapse is hiding.
                    // Only member rows can sit on a real group/root boundary.
                    guard !target.isGroupHeader else { return (groupId, false) }
                    let nextIsSameGroup = context.nextTarget?.groupId == groupId
                    return (groupId, !nextIsSameGroup)
                }
            }

            if context.edge == .top,
               target.groupId == nil,
               let previousGroupId = context.previousTarget?.groupId,
               groupsById[previousGroupId] != nil {
                return (previousGroupId, true)
            }

            return nil
        }

        guard let previousGroupId = context.previousTarget?.groupId,
              groupsById[previousGroupId] != nil else {
            return nil
        }
        return (previousGroupId, true)
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
        if group.isEmpty {
            // There is no member index for a header-only group. The explicit
            // group action still carries the destination group id; the model
            // will promote the dragged workspace to the new anchor and then
            // normalize it into the group's section.
            let targetIndex = max(0, request.workspaces.count - 1)
            return SidebarWorkspaceReorderDropPlan(
                draggedWorkspaceId: request.draggedWorkspaceId,
                indicator: targetIndicator,
                indicatorScope: .group(explicitGroupId),
                action: .reorder(
                    targetIndex: targetIndex,
                    usesTopLevelRows: false,
                    explicitGroupId: explicitGroupId
                )
            )
        }
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
            ? topLevelWorkspaceIds(
                workspaces: request.workspaces,
                workspacesById: workspacesById,
                groupsById: groupsById,
                groupByAnchorId: groupByAnchorId,
                promotingWorkspaceId: request.draggedWorkspaceId
            )
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

        let promotesGroupedWorkspace = usesTopLevelRows &&
            draggedWorkspace.groupId != nil &&
            groupByAnchorId[draggedWorkspace.id] == nil
        // A noncontiguous selection block coalesces at ANY gap, including the
        // dragged row's own edges, so those gaps are real drop targets.
        let blockCoalesces = SidebarWorkspaceDragBlockResolver().blockOccupiesNoncontiguousRows(
            blockIds: request.draggedBlockWorkspaceIds,
            rowSpaceIds: tabIds
        )
        let plannedIndicator = SidebarDropPlanner().indicator(
            draggedTabId: request.draggedWorkspaceId,
            targetTabId: rootTarget.workspaceId,
            tabIds: tabIds,
            pinnedTabIds: pinnedTabIds,
            pointerY: rootTarget.pointerY,
            targetHeight: rootTarget.targetHeight,
            preserveTargetEdge: true,
            suppressesNoOp: !(promotesGroupedWorkspace || blockCoalesces)
        )
        guard let indicator = plannedIndicator else {
            return nil
        }
        let renderedIndicator = renderedRootIndicator(
            planned: indicator,
            requested: requestedIndicator,
            rootTarget: rootTarget
        )

        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: renderedIndicator.indicator,
            indicatorScope: renderedIndicator.scope,
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
            workspacesById: workspacesById,
            groupsById: groupsById,
            groupByAnchorId: groupByAnchorId,
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
        let renderedIndicator = renderedRootIndicator(
            planned: result.indicator,
            requested: requestedIndicator,
            rootTarget: rootTarget
        )
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: request.draggedWorkspaceId,
            indicator: renderedIndicator.indicator,
            indicatorScope: renderedIndicator.scope,
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
            let boundaryIndicator = groupBoundaryIndicator(
                context: context,
                groupId: groupId
            )
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
                    indicator: boundaryIndicator?.indicator
                        ?? SidebarDropIndicator(tabId: nextRootTarget.workspaceId, edge: .top),
                    indicatorScope: boundaryIndicator?.scope ?? .topLevel
                )
            }
            return SidebarWorkspaceReorderRootTarget(
                workspaceId: nil,
                edge: .bottom,
                pointerY: nil,
                targetHeight: nil,
                indicator: boundaryIndicator?.indicator
                    ?? SidebarDropIndicator(tabId: nil, edge: .bottom),
                indicatorScope: boundaryIndicator?.scope ?? .topLevel
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

    private func renderedRootIndicator(
        planned: SidebarDropIndicator,
        requested: SidebarDropIndicator,
        rootTarget: SidebarWorkspaceReorderRootTarget
    ) -> (indicator: SidebarDropIndicator, scope: SidebarWorkspaceReorderDropIndicatorScope) {
        guard planned == requested,
              let indicator = rootTarget.indicator else {
            return (planned, canonicalRootScope(for: rootTarget.indicatorScope))
        }
        return (indicator, rootTarget.indicatorScope)
    }

    private func canonicalRootScope(
        for scope: SidebarWorkspaceReorderDropIndicatorScope
    ) -> SidebarWorkspaceReorderDropIndicatorScope {
        if case .raw = scope {
            return .raw
        }
        return .topLevel
    }

    private func groupBoundaryIndicator(
        context: SidebarWorkspaceReorderHitContext,
        groupId: UUID
    ) -> (indicator: SidebarDropIndicator, scope: SidebarWorkspaceReorderDropIndicatorScope)? {
        guard context.edge == .bottom,
              let target = context.target,
              target.groupId == groupId,
              context.nextTarget?.groupId != groupId else {
            return nil
        }
        return (
            SidebarDropIndicator(tabId: target.workspaceId, edge: .bottom),
            .group(groupId)
        )
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
            if target.groupId == nil || target.isGroupHeader {
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
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupsById: [UUID: SidebarWorkspaceReorderGroupSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot],
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
            ids.insert(
                promotingWorkspaceId,
                at: promotedTopLevelInsertionIndex(
                    ids: ids,
                    groupIndex: groupIndex,
                    promotedIsPinned: promoted.isPinned,
                    workspacesById: workspacesById,
                    groupByAnchorId: groupByAnchorId
                )
            )
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
            workspacesById: workspacesById,
            groupsById: groupsById,
            groupByAnchorId: groupByAnchorId,
            promotingWorkspaceId: promotingWorkspaceId
        ).filter { id in
            topLevelWorkspaceIdIsPinned(id, workspacesById: workspacesById, groupByAnchorId: groupByAnchorId)
        })
    }

    private func promotedTopLevelInsertionIndex(
        ids: [UUID],
        groupIndex: Int,
        promotedIsPinned: Bool,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> Int {
        let desiredIndex = min(groupIndex + 1, ids.count)
        let pinnedCount = ids.reduce(into: 0) { count, id in
            if topLevelWorkspaceIdIsPinned(id, workspacesById: workspacesById, groupByAnchorId: groupByAnchorId) {
                count += 1
            }
        }
        return promotedIsPinned ? min(desiredIndex, pinnedCount) : max(desiredIndex, pinnedCount)
    }

    private func topLevelWorkspaceIdIsPinned(
        _ id: UUID,
        workspacesById: [UUID: SidebarWorkspaceReorderWorkspaceSnapshot],
        groupByAnchorId: [UUID: SidebarWorkspaceReorderGroupSnapshot]
    ) -> Bool {
        if let group = groupByAnchorId[id] {
            return group.isPinned
        }
        return workspacesById[id]?.isPinned == true
    }

    private func pointerY(for edge: SidebarDropEdge, targetHeight: CGFloat?) -> CGFloat? {
        guard let targetHeight else { return nil }
        return edge == .top ? 0 : targetHeight
    }
}

private extension CGRect {
    func verticallyContains(_ y: CGFloat) -> Bool {
        y >= minY && y <= maxY
    }
}
