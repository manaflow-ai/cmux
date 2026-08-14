import Foundation

@testable import CmuxMobileShellModel

/// Independent test oracle for the Mac host's mobile workspace move pipeline.
///
/// This deliberately does not call `MobileWorkspaceMovePolicy`. It follows the
/// host phases in `TerminalController+WorkspaceMove.swift:73-147,183-218`,
/// `WorkspaceGroupCoordinator.swift:207-275`,
/// `WorkspaceReorderCoordinator.swift:164-202,283-350`,
/// `WorkspacesModel+Ordering.swift:37-160,168-243`, and
/// `WorkspacesModel+GroupInvariants.swift:19-87`.
struct MobileWorkspaceHostOrderSimulator {
    let workspaces: [MobileWorkspacePreview]
    let groups: [MobileWorkspaceGroupPreview]

    private var groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview] {
        Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var groupsByAnchorID: [MobileWorkspacePreview.ID: MobileWorkspaceGroupPreview] {
        Dictionary(groups.map { ($0.anchorWorkspaceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func applying(
        _ intent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID
    ) -> [MobileWorkspacePreview] {
        var order = normalized(workspaces)
        guard let movedIndex = order.firstIndex(where: { $0.id == movedWorkspaceID }) else {
            return order
        }
        if intent.movesGroup {
            guard groupsByAnchorID[movedWorkspaceID] != nil, intent.groupID == nil else {
                return order
            }
            return applyingGroupMove(
                movedWorkspaceID: movedWorkspaceID,
                beforeWorkspaceID: intent.beforeWorkspaceID,
                to: order
            )
        }

        guard intent.groupID.map({ groupsByID[$0] != nil }) ?? true else { return order }
        let currentGroupID = validGroupID(order[movedIndex].groupID)
        if currentGroupID != intent.groupID {
            guard groupsByAnchorID[movedWorkspaceID] == nil else { return order }
            if let targetGroupID = intent.groupID {
                let originalTopLevelIDs = topLevelIDs(order)
                order[movedIndex].groupID = targetGroupID
                order = normalized(
                    order,
                    preservingTopLevelIDs: originalTopLevelIDs.filter { $0 != movedWorkspaceID }
                )
                order = placingNewMemberAtGroupEnd(
                    movedWorkspaceID,
                    groupID: targetGroupID,
                    in: order
                )
            } else {
                order[movedIndex].groupID = nil
                order = normalized(order)
            }
        }

        if let beforeWorkspaceID = intent.beforeWorkspaceID {
            order = reordered(movedWorkspaceID, before: beforeWorkspaceID, in: order)
        } else if let targetGroupID = intent.groupID {
            order = reorderedToGroupEnd(movedWorkspaceID, groupID: targetGroupID, in: order)
        } else {
            order = reordered(movedWorkspaceID, toIndex: order.endIndex, in: order)
        }
        return normalized(order)
    }

    /// Mirrors the host's top-level target-index and whole-group reorder path.
    private func applyingGroupMove(
        movedWorkspaceID: MobileWorkspacePreview.ID,
        beforeWorkspaceID: MobileWorkspacePreview.ID?,
        to order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        let topLevelIDs = topLevelIDs(order)
        guard let sourceIndex = topLevelIDs.firstIndex(of: movedWorkspaceID) else { return order }
        let normalizedBeforeID = normalizedTopLevelBeforeID(beforeWorkspaceID, in: order)
        let insertionPosition = normalizedBeforeID.flatMap { topLevelIDs.firstIndex(of: $0) }
            ?? topLevelIDs.count
        let clampedInsertion = max(0, min(insertionPosition, topLevelIDs.count))
        let adjustedIndex = clampedInsertion > sourceIndex ? clampedInsertion - 1 : clampedInsertion
        let targetIndex = clampedTopLevelIndex(
            movedWorkspaceID,
            targetIndex: adjustedIndex,
            topLevelIDs: topLevelIDs,
            in: order
        )
        guard sourceIndex != targetIndex else { return order }
        var desiredIDs = topLevelIDs
        let movedID = desiredIDs.remove(at: sourceIndex)
        desiredIDs.insert(movedID, at: targetIndex)
        return rebuilt(order, desiredTopLevelIDs: desiredIDs)
    }

    /// Mirrors `addWorkspaceToGroup(... placement: .end)` before host reorder.
    private func placingNewMemberAtGroupEnd(
        _ movedWorkspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID,
        in order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        guard let currentIndex = order.firstIndex(where: { $0.id == movedWorkspaceID }),
              let group = groupsByID[groupID] else {
            return order
        }
        let otherMemberIndices = order.indices.filter {
            order[$0].id != movedWorkspaceID && validGroupID(order[$0].groupID) == groupID
        }
        let targetIndex: Int
        if let lastMemberIndex = otherMemberIndices.last {
            targetIndex = lastMemberIndex + 1
        } else if let anchorIndex = order.firstIndex(where: { $0.id == group.anchorWorkspaceID }) {
            targetIndex = anchorIndex + 1
        } else {
            return order
        }
        guard currentIndex != targetIndex else { return order }
        var result = order
        let moved = result.remove(at: currentIndex)
        let insertionIndex = currentIndex < targetIndex ? targetIndex - 1 : targetIndex
        result.insert(moved, at: max(0, min(insertionIndex, result.count)))
        return result
    }

    /// Mirrors `reorderWorkspace(tabId:before:)` and its clamped index plan.
    private func reordered(
        _ movedWorkspaceID: MobileWorkspacePreview.ID,
        before beforeWorkspaceID: MobileWorkspacePreview.ID,
        in order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        guard let currentIndex = order.firstIndex(where: { $0.id == movedWorkspaceID }),
              let beforeIndex = order.firstIndex(where: { $0.id == beforeWorkspaceID }) else {
            return order
        }
        let targetIndex = currentIndex < beforeIndex ? beforeIndex - 1 : beforeIndex
        return reordered(movedWorkspaceID, toIndex: targetIndex, in: order)
    }

    private func reorderedToGroupEnd(
        _ movedWorkspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID,
        in order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        guard let lastMemberIndex = order.lastIndex(where: {
            $0.id != movedWorkspaceID && validGroupID($0.groupID) == groupID
        }) else {
            return order
        }
        return reordered(movedWorkspaceID, toIndex: lastMemberIndex + 1, in: order)
    }

    private func reordered(
        _ movedWorkspaceID: MobileWorkspacePreview.ID,
        toIndex targetIndex: Int,
        in order: [MobileWorkspacePreview]
    ) -> [MobileWorkspacePreview] {
        guard let currentIndex = order.firstIndex(where: { $0.id == movedWorkspaceID }) else {
            return order
        }
        let legalIndex = clampedWorkspaceIndex(order[currentIndex], targetIndex: targetIndex, in: order)
        guard currentIndex != legalIndex else { return order }
        var result = order
        let moved = result.remove(at: currentIndex)
        result.insert(moved, at: max(0, min(legalIndex, result.count)))
        return result
    }

    /// Mirrors `clampedReorderIndex`, including every row of a pinned group.
    private func clampedWorkspaceIndex(
        _ workspace: MobileWorkspacePreview,
        targetIndex: Int,
        in order: [MobileWorkspacePreview]
    ) -> Int {
        let clamped = max(0, min(targetIndex, max(0, order.count - 1)))
        if let groupedIndex = clampedGroupedMemberIndex(workspace, targetIndex: clamped, in: order) {
            return groupedIndex
        }
        let pinnedCount = order.prefix(while: { isGlobalPinnedRow($0) }).count
        return workspace.isPinned
            ? min(clamped, max(0, pinnedCount - 1))
            : max(clamped, pinnedCount)
    }

    private func clampedGroupedMemberIndex(
        _ workspace: MobileWorkspacePreview,
        targetIndex: Int,
        in order: [MobileWorkspacePreview]
    ) -> Int? {
        guard let groupID = validGroupID(workspace.groupID),
              let group = groupsByID[groupID],
              workspace.id != group.anchorWorkspaceID else {
            return nil
        }
        let memberIndices = order.indices.filter { validGroupID(order[$0].groupID) == groupID }
        guard let firstIndex = memberIndices.first, let lastIndex = memberIndices.last else { return nil }
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

    private func clampedTopLevelIndex(
        _ movedWorkspaceID: MobileWorkspacePreview.ID,
        targetIndex: Int,
        topLevelIDs: [MobileWorkspacePreview.ID],
        in order: [MobileWorkspacePreview]
    ) -> Int {
        let clamped = max(0, min(targetIndex, max(0, topLevelIDs.count - 1)))
        let pinnedIDs = pinnedTopLevelIDs(topLevelIDs, in: order)
        let pinnedCount = topLevelIDs.filter { pinnedIDs.contains($0) }.count
        return pinnedIDs.contains(movedWorkspaceID)
            ? min(clamped, max(0, pinnedCount - 1))
            : max(clamped, pinnedCount)
    }

    private func isGlobalPinnedRow(_ workspace: MobileWorkspacePreview) -> Bool {
        if let groupID = validGroupID(workspace.groupID), let group = groupsByID[groupID] {
            return group.isPinned
        }
        return workspace.isPinned
    }

    /// Mirrors `normalizeWorkspaceGroupContiguity` and anchor-first pin tiers.
    private func normalized(
        _ order: [MobileWorkspacePreview],
        preservingTopLevelIDs preferredIDs: [MobileWorkspacePreview.ID]? = nil
    ) -> [MobileWorkspacePreview] {
        let knownGroupIDs = Set(groups.map(\.id))
        let validOrder = order.map { workspace in
            var copy = workspace
            if copy.groupID.map({ !knownGroupIDs.contains($0) }) ?? false {
                copy.groupID = nil
            }
            return copy
        }
        let topLevelIDs = preferredIDs ?? topLevelIDs(validOrder)
        let pinnedIDs = pinnedTopLevelIDs(topLevelIDs, in: validOrder)
        let desiredIDs = topLevelIDs.filter { pinnedIDs.contains($0) }
            + topLevelIDs.filter { !pinnedIDs.contains($0) }
        return rebuilt(validOrder, desiredTopLevelIDs: desiredIDs)
    }

    private func rebuilt(
        _ order: [MobileWorkspacePreview],
        desiredTopLevelIDs: [MobileWorkspacePreview.ID]
    ) -> [MobileWorkspacePreview] {
        let workspacesByID = Dictionary(order.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: order.filter { validGroupID($0.groupID) != nil }) {
            validGroupID($0.groupID)!
        }
        var emittedWorkspaceIDs = Set<MobileWorkspacePreview.ID>()
        var emittedGroupIDs = Set<MobileWorkspaceGroupPreview.ID>()
        var result: [MobileWorkspacePreview] = []
        for id in desiredTopLevelIDs + order.map(\.id) {
            guard let workspace = workspacesByID[id] else { continue }
            if let groupID = validGroupID(workspace.groupID),
               let group = groupsByID[groupID] {
                guard emittedGroupIDs.insert(groupID).inserted else { continue }
                let members = anchorFirst(grouped[groupID] ?? [], anchorID: group.anchorWorkspaceID)
                for member in members where emittedWorkspaceIDs.insert(member.id).inserted {
                    result.append(member)
                }
            } else if emittedWorkspaceIDs.insert(workspace.id).inserted {
                var copy = workspace
                copy.groupID = nil
                result.append(copy)
            }
        }
        return result
    }

    private func topLevelIDs(_ order: [MobileWorkspacePreview]) -> [MobileWorkspacePreview.ID] {
        var emittedGroupIDs = Set<MobileWorkspaceGroupPreview.ID>()
        var result: [MobileWorkspacePreview.ID] = []
        for workspace in order {
            if let groupID = validGroupID(workspace.groupID), let group = groupsByID[groupID] {
                if emittedGroupIDs.insert(groupID).inserted {
                    result.append(group.anchorWorkspaceID)
                }
            } else {
                result.append(workspace.id)
            }
        }
        return result
    }

    private func pinnedTopLevelIDs(
        _ ids: [MobileWorkspacePreview.ID],
        in order: [MobileWorkspacePreview]
    ) -> Set<MobileWorkspacePreview.ID> {
        let workspacesByID = Dictionary(order.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(ids.filter { id in
            groupsByAnchorID[id]?.isPinned ?? (workspacesByID[id]?.isPinned == true)
        })
    }

    private func normalizedTopLevelBeforeID(
        _ beforeWorkspaceID: MobileWorkspacePreview.ID?,
        in order: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        guard let beforeWorkspaceID,
              let workspace = order.first(where: { $0.id == beforeWorkspaceID }),
              let groupID = validGroupID(workspace.groupID),
              let group = groupsByID[groupID] else {
            return beforeWorkspaceID
        }
        return group.anchorWorkspaceID
    }

    private func anchorFirst(
        _ members: [MobileWorkspacePreview],
        anchorID: MobileWorkspacePreview.ID
    ) -> [MobileWorkspacePreview] {
        guard let anchor = members.first(where: { $0.id == anchorID }) else { return members }
        let remaining = members.filter { $0.id != anchorID }
        return [anchor] + remaining.filter(\.isPinned) + remaining.filter { !$0.isPinned }
    }

    private func validGroupID(
        _ groupID: MobileWorkspaceGroupPreview.ID?
    ) -> MobileWorkspaceGroupPreview.ID? {
        guard let groupID, groupsByID[groupID] != nil else { return nil }
        return groupID
    }
}
