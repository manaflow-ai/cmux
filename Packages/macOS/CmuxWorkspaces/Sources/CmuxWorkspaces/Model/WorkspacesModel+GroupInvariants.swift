public import Foundation

// Group-section invariant maintenance over the model's own tabs/groups
// storage, lifted one-for-one from the legacy private TabManager helpers:
// contiguous group runs, anchor-first member order, pinned tier above
// unpinned, and the group-dissolve lifecycle bound to anchor removal.
extension WorkspacesModel {
    /// Sets a workspace's group membership (no-op when unchanged).
    func assignGroup(workspaceId: UUID, groupId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard tab.groupId != groupId else { return }
        tab.groupId = groupId
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

        var groupedByGroupId: [UUID: [Tab]] = [:]
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for tab in tabs {
            if let groupId = tab.groupId {
                groupedByGroupId[groupId, default: []].append(tab)
            }
        }

        var emittedWorkspaceIds = Set<UUID>()
        var emittedGroupIds = Set<UUID>()
        var reordered: [Tab] = []
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
    public func normalizeWorkspaceGroupContiguity(
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
    /// didSet hook. No-op when the workspace is ungrouped or its group is already expanded.
    public func expandWorkspaceGroupForSelectionIfNeeded() {
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

    /// Hoist promoted (non-anchor) members to the front of their group's
    /// member run, right after the anchor, preserving each group's position.
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

        var replacementMembersByGroupId: [UUID: [Tab]] = [:]
        for (groupId, promotedIds) in promotedIdsByGroupId {
            guard let group = groupsById[groupId] else { continue }
            let orderedMembers = anchorFirst(
                tabs.filter { $0.groupId == groupId },
                anchorId: group.anchorWorkspaceId
            )
            guard let anchor = orderedMembers.first(where: { $0.id == group.anchorWorkspaceId }) else { continue }
            var emittedPromotedIds = Set<UUID>()
            let promotedMembers = promotedIds.compactMap { id -> Tab? in
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
        var reordered: [Tab] = []
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

    /// If `closedWorkspaceId` was the anchor of any group, dissolve that group:
    /// remaining members lose their `groupId` and stay in `tabs` as ungrouped
    /// workspaces. Caller is responsible for having already removed the closed
    /// workspace from `tabs`.
    public func dissolveGroupsAnchoredBy(closedWorkspaceId: UUID) {
        let dissolvedGroupIds = workspaceGroups
            .filter { $0.anchorWorkspaceId == closedWorkspaceId }
            .map(\.id)
        guard !dissolvedGroupIds.isEmpty else { return }
        for gid in dissolvedGroupIds {
            for tab in tabs where tab.groupId == gid {
                tab.groupId = nil
            }
        }
        workspaceGroups.removeAll { dissolvedGroupIds.contains($0.id) }
        // Newly-ungrouped members may be sitting above other groups, which
        // violates the renderer's pinned-solo / pinned-groups / unpinned-
        // groups / ungrouped-unpinned ordering invariant. Renormalize so
        // they slide into the ungrouped tier at the bottom.
        normalizeWorkspaceGroupContiguity()
    }
}
