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


// MARK: - Workspace Group Ordering
extension TabManager {
    func assignGroup(workspaceId: UUID, groupId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard tab.groupId != groupId else { return }
        tab.groupId = groupId
    }

    /// Place a freshly-created group where its first child already was.
    /// This keeps "New Group from Selection" visually stable while still
    /// making every affected group contiguous and anchor-first. It
    /// intentionally preserves top-level order because changing that outer
    /// position is the jump this creation path is avoiding.
    func placeNewWorkspaceGroupAtCreationPosition(
        groupId: UUID,
        anchorId: UUID,
        childWorkspaceIds: [UUID],
        originalTabOrder: [UUID]
    ) {
        let childIdSet = Set(childWorkspaceIds)
        let orderedChildIds = originalTabOrder.filter { childIdSet.contains($0) }
        guard let insertionIndex = originalTabOrder.firstIndex(where: { childIdSet.contains($0) }),
              !orderedChildIds.isEmpty else {
            normalizeWorkspaceGroupContiguity()
            return
        }

        var desiredIds: [UUID] = []
        desiredIds.reserveCapacity(tabs.count)
        for (index, id) in originalTabOrder.enumerated() {
            if index == insertionIndex {
                desiredIds.append(anchorId)
                desiredIds.append(contentsOf: orderedChildIds)
            }
            if !childIdSet.contains(id) {
                desiredIds.append(id)
            }
        }
        normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: topLevelWorkspaceIdsPreservingOrder(desiredIds)
        )
        if workspaceGroups.contains(where: { $0.id == groupId }) {
            syncWorkspaceGroupsOrderToAnchorOrder()
        }
    }

    /// Rebuild `tabs` by walking a desired top-level workspace order and
    /// emitting each workspace group as one contiguous run at its first
    /// encountered member.
    func normalizeWorkspaceGroupRunsPreservingOrder(_ desiredIds: [UUID]) {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let knownGroupIds = Set(groupsById.keys)
        for tab in tabs where tab.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            tab.groupId = nil
        }

        var groupedByGroupId: [UUID: [Workspace]] = [:]
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for tab in tabs {
            if let groupId = tab.groupId {
                groupedByGroupId[groupId, default: []].append(tab)
            }
        }

        var emittedWorkspaceIds = Set<UUID>()
        var emittedGroupIds = Set<UUID>()
        var reordered: [Workspace] = []
        reordered.reserveCapacity(tabs.count)

        func appendWorkspaceOrGroup(for id: UUID) {
            guard let tab = tabsById[id] else { return }
            if let groupId = tab.groupId,
               let group = groupsById[groupId],
               emittedGroupIds.insert(groupId).inserted {
                let members = anchorFirst(groupedByGroupId[groupId] ?? [], anchorId: group.anchorWorkspaceId)
                for member in members where emittedWorkspaceIds.insert(member.id).inserted {
                    reordered.append(member)
                }
            } else if tab.groupId == nil,
                      emittedWorkspaceIds.insert(tab.id).inserted {
                reordered.append(tab)
            }
        }

        for id in desiredIds {
            appendWorkspaceOrGroup(for: id)
        }
        for tab in tabs where !emittedWorkspaceIds.contains(tab.id) {
            appendWorkspaceOrGroup(for: tab.id)
        }

        tabs = reordered
    }

    /// Reorder `tabs` so each group stays contiguous and anchor-first while
    /// preserving top-level row order inside the pinned and unpinned tiers:
    /// 1. Pinned top-level rows (pinned workspaces and pinned groups).
    /// 2. Unpinned top-level rows (workspaces and groups).
    ///
    /// Within each group, members keep their relative order. A group anchor is
    /// the group's top-level row for ordering purposes.
    func normalizeWorkspaceGroupContiguity(
        preservingTopLevelIds preferredTopLevelIds: [UUID]? = nil
    ) {
        guard !tabs.isEmpty else { return }
        let knownGroupIds = Set(workspaceGroups.map(\.id))
        for tab in tabs where tab.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            tab.groupId = nil
        }
        let topLevelIds = preferredTopLevelIds ?? sidebarTopLevelWorkspaceIds()
        let pinnedTopLevelIds = sidebarTopLevelPinnedWorkspaceIds()
        let desiredIds = topLevelIds.filter { pinnedTopLevelIds.contains($0) }
            + topLevelIds.filter { !pinnedTopLevelIds.contains($0) }
        // Always reassign so SwiftUI consumers re-evaluate row modifiers that
        // depend on `Workspace.groupId` even when the array contents are
        // unchanged.
        normalizeWorkspaceGroupRunsPreservingOrder(desiredIds)
        syncWorkspaceGroupsOrderToAnchorOrder()
    }

    /// Ensure the group containing the newly-selected workspace is expanded, so the
    /// selected row is actually visible in the sidebar. Called from `selectedTabId`'s
    /// didSet. No-op when the workspace is ungrouped or its group is already expanded.
    func expandWorkspaceGroupForSelectionIfNeeded() {
        guard let selectedTabId,
              let groupId = tabs.first(where: { $0.id == selectedTabId })?.groupId,
              let index = workspaceGroups.firstIndex(where: { $0.id == groupId }),
              workspaceGroups[index].isCollapsed else {
            return
        }
        // The anchor is the group header's visible representation, so
        // focusing it doesn't hide it. Skip auto-expand when the focused
        // workspace IS the group's anchor — that lets users work in the
        // anchor while keeping the rest of the group folded away.
        guard workspaceGroups[index].anchorWorkspaceId != selectedTabId else { return }
        workspaceGroups[index].isCollapsed = false
    }

    /// Reorder `workspaceGroups` so each group's relative position matches
    /// the order its anchor occupies in `tabs[]`. Call this after an anchor
    /// reorder so later group-slot commands observe the same order the user
    /// sees in the sidebar.
    func syncWorkspaceGroupsOrderToAnchorOrder() {
        let anchorIndex: [UUID: Int] = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        workspaceGroups.sort { lhs, rhs in
            let l = anchorIndex[lhs.anchorWorkspaceId] ?? Int.max
            let r = anchorIndex[rhs.anchorWorkspaceId] ?? Int.max
            return l < r
        }
    }

    func isWorkspaceGroupAnchor(_ workspaceId: UUID) -> Bool {
        workspaceGroups.contains { $0.anchorWorkspaceId == workspaceId }
    }

    func topLevelWorkspaceIds(for workspaces: [Workspace]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var emittedIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            let topLevelId: UUID
            if let groupId = workspace.groupId,
               let group = groupsById[groupId] {
                topLevelId = group.anchorWorkspaceId
            } else {
                topLevelId = workspace.id
            }
            if emittedIds.insert(topLevelId).inserted {
                ids.append(topLevelId)
            }
        }
        return ids
    }

    func moveWorkspaceGroupMembersAfterAnchors(workspaceIds: [UUID]) {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var promotedIdsByGroupId: [UUID: [UUID]] = [:]
        for workspaceId in workspaceIds {
            guard let tab = tabsById[workspaceId],
                  let groupId = tab.groupId,
                  let group = groupsById[groupId],
                  tab.id != group.anchorWorkspaceId else {
                continue
            }
            promotedIdsByGroupId[groupId, default: []].append(workspaceId)
        }
        guard !promotedIdsByGroupId.isEmpty else { return }

        var replacementMembersByGroupId: [UUID: [Workspace]] = [:]
        for (groupId, promotedIds) in promotedIdsByGroupId {
            guard let group = groupsById[groupId] else { continue }
            let orderedMembers = anchorFirst(
                tabs.filter { $0.groupId == groupId },
                anchorId: group.anchorWorkspaceId
            )
            guard let anchor = orderedMembers.first(where: { $0.id == group.anchorWorkspaceId }) else { continue }
            var emittedPromotedIds = Set<UUID>()
            let promotedMembers = promotedIds.compactMap { id -> Workspace? in
                guard emittedPromotedIds.insert(id).inserted else { return nil }
                return tabsById[id]
            }
            let promotedIdSet = Set(promotedMembers.map(\.id))
            let remainingMembers = orderedMembers.filter {
                $0.id != group.anchorWorkspaceId && !promotedIdSet.contains($0.id)
            }
            replacementMembersByGroupId[groupId] = [anchor] + promotedMembers + remainingMembers
        }
        guard !replacementMembersByGroupId.isEmpty else { return }

        var emittedGroupIds = Set<UUID>()
        var reordered: [Workspace] = []
        reordered.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let replacementMembers = replacementMembersByGroupId[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    reordered.append(contentsOf: replacementMembers)
                }
            } else {
                reordered.append(tab)
            }
        }
        tabs = reordered
    }

    func sidebarTopLevelWorkspaceIds(promotingWorkspaceId promotedWorkspaceId: UUID? = nil) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)
        for tab in tabs {
            if let groupId = tab.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }
        if let promotedWorkspaceId,
           !ids.contains(promotedWorkspaceId),
           let tab = tabs.first(where: { $0.id == promotedWorkspaceId }),
           let groupId = tab.groupId,
           let group = groupsById[groupId],
           let groupIndex = ids.firstIndex(of: group.anchorWorkspaceId) {
            ids.insert(promotedWorkspaceId, at: min(groupIndex + 1, ids.count))
        }
        return ids
    }

    private func topLevelWorkspaceIdsPreservingOrder(_ desiredIds: [UUID]) -> [UUID] {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var emittedWorkspaceIds = Set<UUID>()
        var emittedGroupIds = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(tabs.count)

        func appendTopLevelId(for id: UUID) {
            guard let tab = tabsById[id],
                  emittedWorkspaceIds.insert(tab.id).inserted else { return }
            if let groupId = tab.groupId,
               let group = groupsById[groupId] {
                if emittedGroupIds.insert(groupId).inserted {
                    ids.append(group.anchorWorkspaceId)
                }
            } else {
                ids.append(tab.id)
            }
        }

        for id in desiredIds {
            appendTopLevelId(for: id)
        }
        for tab in tabs where !emittedWorkspaceIds.contains(tab.id) {
            appendTopLevelId(for: tab.id)
        }
        return ids
    }

    func sidebarTopLevelPinnedWorkspaceIds() -> Set<UUID> {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return Set(sidebarTopLevelWorkspaceIds().filter { id in
            if let group = groupsByAnchorId[id] {
                return group.isPinned
            }
            return tabsById[id]?.isPinned == true
        })
    }

    func clampedTopLevelReorderIndex(
        forWorkspaceId workspaceId: UUID,
        targetIndex: Int,
        topLevelIds: [UUID]
    ) -> Int {
        let clamped = max(0, min(targetIndex, max(0, topLevelIds.count - 1)))
        let pinnedIds = sidebarTopLevelPinnedWorkspaceIds()
        let pinnedCount = topLevelIds.reduce(into: 0) { count, id in
            if pinnedIds.contains(id) {
                count += 1
            }
        }
        if pinnedIds.contains(workspaceId) {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    /// Helper for `normalizeWorkspaceGroupContiguity`: hoist the anchor to
    /// the front of its group's member list, then keep pinned member
    /// workspaces above unpinned member workspaces while preserving relative
    /// order inside each tier. No-op when the anchor isn't actually in the
    /// list (anchor lifecycle elsewhere ensures it always should be).
    private func anchorFirst(_ members: [Workspace], anchorId: UUID) -> [Workspace] {
        guard let anchorIndex = members.firstIndex(where: { $0.id == anchorId }) else {
            return members
        }
        let anchor = members[anchorIndex]
        let nonAnchors = members.filter { $0.id != anchorId }
        return [anchor] + nonAnchors.filter(\.isPinned) + nonAnchors.filter { !$0.isPinned }
    }

    func clampedReorderIndex(for workspace: Workspace, targetIndex: Int) -> Int {
        let clamped = max(0, min(targetIndex, tabs.count - 1))
        if let groupClamp = clampedGroupedMemberReorderIndex(
            for: workspace,
            clampedTargetIndex: clamped
        ) {
            return groupClamp
        }
        let pinnedCount = leadingGlobalPinnedRowCount()
        if workspace.isPinned {
            return min(clamped, max(0, pinnedCount - 1))
        }
        return max(clamped, pinnedCount)
    }

    private func clampedGroupedMemberReorderIndex(
        for workspace: Workspace,
        clampedTargetIndex: Int
    ) -> Int? {
        guard let groupId = workspace.groupId,
              let group = workspaceGroups.first(where: { $0.id == groupId }),
              workspace.id != group.anchorWorkspaceId else {
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
        let lowerBound = workspace.isPinned
            ? min(firstIndex + 1, lastIndex)
            : min(firstIndex + 1 + pinnedMemberCount, lastIndex)
        let upperBound = workspace.isPinned
            ? max(firstIndex + pinnedMemberCount, lowerBound)
            : lastIndex
        return min(max(clampedTargetIndex, lowerBound), upperBound)
    }

    func leadingGlobalPinnedRowCount() -> Int {
        var count = 0
        for tab in tabs {
            guard isGlobalPinnedRow(tab) else { break }
            count += 1
        }
        return count
    }

    private func isGlobalPinnedRow(_ tab: Workspace) -> Bool {
        if let groupId = tab.groupId,
           let group = workspaceGroups.first(where: { $0.id == groupId }) {
            return group.isPinned
        }
        return tab.isPinned
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

}
