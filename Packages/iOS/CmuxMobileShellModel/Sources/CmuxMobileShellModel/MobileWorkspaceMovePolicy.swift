import Foundation

/// Host-style workspace move normalization shared by iOS intent resolution and optimistic ordering.
struct MobileWorkspaceMovePolicy {
    let workspaces: [MobileWorkspacePreview]
    let groups: [MobileWorkspaceGroupPreview]
    // One synchronous drop runs the policy across per-workspace filters,
    // clamps, and signatures; the lookup tables are built once here instead of
    // per access.
    private let groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    private let groupByAnchorID: [MobileWorkspacePreview.ID: MobileWorkspaceGroupPreview]

    init(workspaces: [MobileWorkspacePreview], groups: [MobileWorkspaceGroupPreview]) {
        self.workspaces = workspaces
        self.groups = groups
        groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupByAnchorID = Dictionary(groups.map { ($0.anchorWorkspaceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func normalizedIntent(
        _ proposed: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID
    ) -> MobileWorkspaceMoveIntent? {
        guard workspaces.contains(where: { $0.id == movedWorkspaceID }) else { return nil }
        guard proposed.beforeWorkspaceID.map({ beforeID in
            workspaces.contains(where: { $0.id == beforeID })
        }) ?? true else {
            return nil
        }
        if let groupID = proposed.groupID, groupsByID[groupID] == nil {
            return nil
        }
        if proposed.movesGroup {
            guard groupByAnchorID[movedWorkspaceID] != nil, proposed.groupID == nil else {
                return nil
            }
        } else if proposed.groupID != nil, groupByAnchorID[movedWorkspaceID] != nil {
            return nil
        }

        let predicted = applyingHostMove(proposed, movedWorkspaceID: movedWorkspaceID)
        guard orderSignature(predicted) != orderSignature(workspaces) else { return nil }

        if proposed.movesGroup {
            return MobileWorkspaceMoveIntent(
                groupID: nil,
                beforeWorkspaceID: topLevelBeforeWorkspaceID(afterMoving: movedWorkspaceID, in: predicted),
                movesGroup: true
            )
        }
        let moved = predicted.first { $0.id == movedWorkspaceID }
        return MobileWorkspaceMoveIntent(
            groupID: validGroupID(moved?.groupID),
            beforeWorkspaceID: workspaceID(after: movedWorkspaceID, in: predicted),
            movesGroup: false
        )
    }

    func applyingHostMove(
        _ intent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID
    ) -> [MobileWorkspacePreview] {
        var order = normalizedGroupRuns(workspaces)
        guard let movedIndex = order.firstIndex(where: { $0.id == movedWorkspaceID }) else {
            return order
        }
        if intent.movesGroup {
            guard groupByAnchorID[movedWorkspaceID] != nil else { return order }
            return applyingTopLevelMove(
                movedWorkspaceID: movedWorkspaceID,
                beforeWorkspaceID: intent.beforeWorkspaceID,
                in: order,
                promotesGroupedWorkspace: false
            )
        }

        let moved = order[movedIndex]
        if validGroupID(moved.groupID) != intent.groupID {
            guard !isAnchor(movedWorkspaceID) else { return order }
            if let targetGroupID = intent.groupID {
                let originalTopLevelIds = topLevelWorkspaceIDs(in: order)
                order[movedIndex].groupID = targetGroupID
                order = normalizedGroupRuns(
                    order,
                    preservingTopLevelIDs: originalTopLevelIds.filter { $0 != movedWorkspaceID }
                )
            } else {
                order[movedIndex].groupID = nil
                order = normalizedGroupRuns(order)
            }
        }

        if let beforeWorkspaceID = intent.beforeWorkspaceID {
            order = applyingWorkspaceReorder(
                movedWorkspaceID: movedWorkspaceID,
                beforeWorkspaceID: beforeWorkspaceID,
                in: order
            )
        } else if let targetGroupID = intent.groupID {
            order = applyingWorkspaceReorderToGroupEnd(
                movedWorkspaceID: movedWorkspaceID,
                groupID: targetGroupID,
                in: order
            )
        } else {
            order = applyingWorkspaceReorder(
                movedWorkspaceID: movedWorkspaceID,
                targetIndex: order.endIndex,
                in: order
            )
        }
        return normalizedGroupRuns(order)
    }

    private func applyingTopLevelMove(
        movedWorkspaceID: MobileWorkspacePreview.ID,
        beforeWorkspaceID: MobileWorkspacePreview.ID?,
        in order: [MobileWorkspacePreview],
        promotesGroupedWorkspace: Bool
    ) -> [MobileWorkspacePreview] {
        var mutable = order
        let topLevelIds = topLevelWorkspaceIDs(
            in: mutable,
            promotingWorkspaceID: promotesGroupedWorkspace ? movedWorkspaceID : nil
        )
        guard let fromIndex = topLevelIds.firstIndex(of: movedWorkspaceID) else {
            return mutable
        }
        let normalizedBeforeID = topLevelNormalizedBeforeWorkspaceID(beforeWorkspaceID, in: mutable)
        let insertionPosition = normalizedBeforeID.flatMap { topLevelIds.firstIndex(of: $0) } ?? topLevelIds.count
        let adjustedIndex = insertionPosition > fromIndex ? insertionPosition - 1 : insertionPosition
        let targetIndex = clampedTopLevelIndex(
            movedWorkspaceID: movedWorkspaceID,
            targetIndex: adjustedIndex,
            topLevelIds: topLevelIds,
            in: mutable
        )

        var desiredTopLevelIds = topLevelIds
        if fromIndex != targetIndex {
            let movedID = desiredTopLevelIds.remove(at: fromIndex)
            desiredTopLevelIds.insert(movedID, at: targetIndex)
        }
        if promotesGroupedWorkspace,
           let index = mutable.firstIndex(where: { $0.id == movedWorkspaceID }),
           !isAnchor(movedWorkspaceID) {
            mutable[index].groupID = nil
        }
        return normalizedGroupRuns(mutable, preservingTopLevelIDs: desiredTopLevelIds)
    }

    private func applyingWorkspaceReorder(
        movedWorkspaceID: MobileWorkspacePreview.ID,
        beforeWorkspaceID: MobileWorkspacePreview.ID,
        in order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        guard let currentIndex = order.firstIndex(where: { $0.id == movedWorkspaceID }),
              let beforeIndex = order.firstIndex(where: { $0.id == beforeWorkspaceID }) else {
            return order
        }
        let targetIndex = currentIndex < beforeIndex ? beforeIndex - 1 : beforeIndex
        return applyingWorkspaceReorder(
            movedWorkspaceID: movedWorkspaceID,
            targetIndex: targetIndex,
            in: order
        )
    }

    private func applyingWorkspaceReorderToGroupEnd(
        movedWorkspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID,
        in order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        guard let lastMemberIndex = order.lastIndex(where: {
            $0.id != movedWorkspaceID && validGroupID($0.groupID) == groupID
        }) else {
            return order
        }
        return applyingWorkspaceReorder(
            movedWorkspaceID: movedWorkspaceID,
            targetIndex: order.index(after: lastMemberIndex),
            in: order
        )
    }

    private func applyingWorkspaceReorder(
        movedWorkspaceID: MobileWorkspacePreview.ID,
        targetIndex: Int,
        in order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        guard let currentIndex = order.firstIndex(where: { $0.id == movedWorkspaceID }) else {
            return order
        }
        let clampedTargetIndex = clampedWorkspaceIndex(
            for: order[currentIndex],
            targetIndex: targetIndex,
            in: order
        )
        guard currentIndex != clampedTargetIndex else { return order }
        var mutable = order
        let moved = mutable.remove(at: currentIndex)
        mutable.insert(moved, at: max(0, min(clampedTargetIndex, mutable.count)))
        return mutable
    }

    private func normalizedGroupRuns(
        _ order: [MobileWorkspacePreview],
        preservingTopLevelIDs preferredTopLevelIds: [MobileWorkspacePreview.ID]? = nil
    ) -> [MobileWorkspacePreview] {
        let knownGroupIds = Set(groups.map(\.id))
        var mutable = order.map { workspace in
            var copy = workspace
            if copy.groupID.map({ !knownGroupIds.contains($0) }) ?? false {
                copy.groupID = nil
            }
            return copy
        }
        let topLevelIds = preferredTopLevelIds ?? topLevelWorkspaceIDs(in: mutable)
        let pinnedTopLevelIds = pinnedTopLevelWorkspaceIDs(topLevelIds, in: mutable)
        let desiredIds = topLevelIds.filter { pinnedTopLevelIds.contains($0) }
            + topLevelIds.filter { !pinnedTopLevelIds.contains($0) }
        mutable = normalizedGroupRuns(mutable, desiredWorkspaceIDs: desiredIds)
        return mutable
    }

    private func normalizedGroupRuns(
        _ order: [MobileWorkspacePreview],
        desiredWorkspaceIDs: [MobileWorkspacePreview.ID]
    ) -> [MobileWorkspacePreview] {
        let groupedByGroupID = Dictionary(grouping: order.filter {
            validGroupID($0.groupID) != nil
        }, by: { validGroupID($0.groupID)! })
        let workspacesByID = Dictionary(order.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var emittedWorkspaceIDs = Set<MobileWorkspacePreview.ID>()
        var emittedGroupIDs = Set<MobileWorkspaceGroupPreview.ID>()
        var reordered: [MobileWorkspacePreview] = []
        reordered.reserveCapacity(order.count)

        func appendWorkspaceOrGroup(for id: MobileWorkspacePreview.ID) {
            guard let workspace = workspacesByID[id] else { return }
            if let groupID = validGroupID(workspace.groupID),
               let group = groupsByID[groupID],
               emittedGroupIDs.insert(groupID).inserted {
                let members = anchorFirst(groupedByGroupID[groupID] ?? [], anchorID: group.anchorWorkspaceID)
                for member in members where emittedWorkspaceIDs.insert(member.id).inserted {
                    reordered.append(member)
                }
            } else if validGroupID(workspace.groupID) == nil,
                      emittedWorkspaceIDs.insert(workspace.id).inserted {
                var copy = workspace
                copy.groupID = nil
                reordered.append(copy)
            }
        }

        for id in desiredWorkspaceIDs {
            appendWorkspaceOrGroup(for: id)
        }
        for workspace in order where !emittedWorkspaceIDs.contains(workspace.id) {
            appendWorkspaceOrGroup(for: workspace.id)
        }
        return reordered
    }

    private func topLevelWorkspaceIDs(
        in order: [MobileWorkspacePreview],
        promotingWorkspaceID promotedWorkspaceID: MobileWorkspacePreview.ID? = nil
    ) -> [MobileWorkspacePreview.ID] {
        let workspacesByID = Dictionary(order.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var emittedGroupIDs = Set<MobileWorkspaceGroupPreview.ID>()
        var ids: [MobileWorkspacePreview.ID] = []
        ids.reserveCapacity(order.count)
        for workspace in order {
            if let groupID = validGroupID(workspace.groupID),
               let group = groupsByID[groupID] {
                if emittedGroupIDs.insert(groupID).inserted {
                    ids.append(group.anchorWorkspaceID)
                }
            } else {
                ids.append(workspace.id)
            }
        }
        if let promotedWorkspaceID,
           !ids.contains(promotedWorkspaceID),
           let workspace = workspacesByID[promotedWorkspaceID],
           let groupID = validGroupID(workspace.groupID),
           let group = groupsByID[groupID],
           let groupIndex = ids.firstIndex(of: group.anchorWorkspaceID) {
            let insertionIndex = promotedTopLevelInsertionIndex(
                ids: ids,
                groupIndex: groupIndex,
                promotedIsPinned: workspace.isPinned,
                in: order
            )
            ids.insert(promotedWorkspaceID, at: insertionIndex)
        }
        return ids
    }

    private func pinnedTopLevelWorkspaceIDs(
        _ ids: [MobileWorkspacePreview.ID],
        in order: [MobileWorkspacePreview]
    ) -> Set<MobileWorkspacePreview.ID> {
        let workspacesByID = Dictionary(order.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(ids.filter { id in
            groupByAnchorID[id]?.isPinned ?? (workspacesByID[id]?.isPinned == true)
        })
    }

    private func promotedTopLevelInsertionIndex(
        ids: [MobileWorkspacePreview.ID],
        groupIndex: Int,
        promotedIsPinned: Bool,
        in order: [MobileWorkspacePreview]
    ) -> Int {
        let desiredIndex = min(groupIndex + 1, ids.count)
        let pinnedIds = pinnedTopLevelWorkspaceIDs(ids, in: order)
        let pinnedCount = ids.reduce(into: 0) { count, id in
            if pinnedIds.contains(id) {
                count += 1
            }
        }
        return promotedIsPinned ? min(desiredIndex, pinnedCount) : max(desiredIndex, pinnedCount)
    }

    private func clampedTopLevelIndex(
        movedWorkspaceID: MobileWorkspacePreview.ID,
        targetIndex: Int,
        topLevelIds: [MobileWorkspacePreview.ID],
        in order: [MobileWorkspacePreview]
    ) -> Int {
        let clamped = max(0, min(targetIndex, max(0, topLevelIds.count - 1)))
        let pinnedIds = pinnedTopLevelWorkspaceIDs(topLevelIds, in: order)
        let pinnedCount = topLevelIds.reduce(into: 0) { count, id in
            if pinnedIds.contains(id) {
                count += 1
            }
        }
        if pinnedIds.contains(movedWorkspaceID) {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    private func clampedWorkspaceIndex(
        for workspace: MobileWorkspacePreview,
        targetIndex: Int,
        in order: [MobileWorkspacePreview]
    ) -> Int {
        let clamped = max(0, min(targetIndex, max(0, order.count - 1)))
        if let groupClamp = clampedGroupedMemberIndex(for: workspace, targetIndex: clamped, in: order) {
            return groupClamp
        }
        let pinnedCount = leadingGlobalPinnedRowCount(in: order)
        if workspace.isPinned {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    private func clampedGroupedMemberIndex(
        for workspace: MobileWorkspacePreview,
        targetIndex: Int,
        in order: [MobileWorkspacePreview]
    ) -> Int? {
        guard let groupID = validGroupID(workspace.groupID),
              let group = groupsByID[groupID],
              workspace.id != group.anchorWorkspaceID else {
            return nil
        }
        let memberIndices = order.indices.filter { validGroupID(order[$0].groupID) == groupID }
        guard let firstIndex = memberIndices.first,
              let lastIndex = memberIndices.last else {
            return nil
        }
        let pinnedMemberCount = memberIndices.reduce(into: 0) { count, index in
            let member = order[index]
            if member.id != group.anchorWorkspaceID, member.isPinned {
                count += 1
            }
        }
        let lowerBound = workspace.isPinned
            ? min(firstIndex + 1, lastIndex)
            : min(firstIndex + 1 + pinnedMemberCount, lastIndex)
        let upperBound = workspace.isPinned
            ? max(firstIndex + pinnedMemberCount, lowerBound)
            : lastIndex
        return min(max(targetIndex, lowerBound), upperBound)
    }

    private func leadingGlobalPinnedRowCount(in order: [MobileWorkspacePreview]) -> Int {
        var count = 0
        for workspace in order {
            guard isGlobalPinnedRow(workspace) else { break }
            count += 1
        }
        return count
    }

    private func isGlobalPinnedRow(_ workspace: MobileWorkspacePreview) -> Bool {
        if let groupID = validGroupID(workspace.groupID),
           let group = groupsByID[groupID] {
            return group.isPinned
        }
        return workspace.isPinned
    }

    private func topLevelNormalizedBeforeWorkspaceID(
        _ beforeWorkspaceID: MobileWorkspacePreview.ID?,
        in order: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        guard let beforeWorkspaceID,
              let beforeWorkspace = order.first(where: { $0.id == beforeWorkspaceID }),
              let groupID = validGroupID(beforeWorkspace.groupID),
              let group = groupsByID[groupID] else {
            return beforeWorkspaceID
        }
        return group.anchorWorkspaceID
    }

    private func topLevelBeforeWorkspaceID(
        afterMoving movedWorkspaceID: MobileWorkspacePreview.ID,
        in order: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        let topLevelIds = topLevelWorkspaceIDs(in: order)
        guard let index = topLevelIds.firstIndex(of: movedWorkspaceID) else { return nil }
        let nextIndex = topLevelIds.index(after: index)
        guard nextIndex < topLevelIds.endIndex else { return nil }
        return topLevelIds[nextIndex]
    }

    private func workspaceID(
        after movedWorkspaceID: MobileWorkspacePreview.ID,
        in order: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        guard let index = order.firstIndex(where: { $0.id == movedWorkspaceID }) else { return nil }
        let nextIndex = order.index(after: index)
        guard nextIndex < order.endIndex else { return nil }
        return order[nextIndex].id
    }

    private func anchorFirst(
        _ members: [MobileWorkspacePreview],
        anchorID: MobileWorkspacePreview.ID
    ) -> [MobileWorkspacePreview] {
        guard let anchor = members.first(where: { $0.id == anchorID }) else {
            return members
        }
        let nonAnchors = members.filter { $0.id != anchorID }
        return [anchor] + nonAnchors.filter(\.isPinned) + nonAnchors.filter { !$0.isPinned }
    }

    private func validGroupID(
        _ groupID: MobileWorkspaceGroupPreview.ID?
    ) -> MobileWorkspaceGroupPreview.ID? {
        guard let groupID, groupsByID[groupID] != nil else { return nil }
        return groupID
    }

    private func isAnchor(_ workspaceID: MobileWorkspacePreview.ID) -> Bool {
        groupByAnchorID[workspaceID] != nil
    }

    private func orderSignature(
        _ order: [MobileWorkspacePreview]
    ) -> [MobileWorkspaceOrderSignature] {
        order.map {
            MobileWorkspaceOrderSignature(id: $0.id, groupID: validGroupID($0.groupID), isPinned: $0.isPinned)
        }
    }
}
