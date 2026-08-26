public import Foundation

// Group-section invariant maintenance over the model's own tabs/groups
// storage, lifted one-for-one from the legacy private TabManager helpers:
// contiguous group runs, anchor-first member order, pinned tier above
// unpinned, and the group-anchor lifecycle bound to anchor removal.
extension WorkspacesModel {
    /// Sets a workspace's group membership and preserves selected-row visibility.
    func assignGroup(workspaceId: UUID, groupId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard tab.groupId != groupId else { return }
        tab.groupId = groupId
        if let groupId,
           let groupIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }),
           workspaceGroups[groupIndex].liveAnchorWorkspaceId == nil {
            // The first workspace added to an empty pinned group becomes its
            // live header anchor. The placeholder identity is retained only
            // while the group has no members.
            workspaceGroups[groupIndex].anchor = .workspace(workspaceId)
        }
        expandWorkspaceGroupForSelectionIfNeeded()
    }

    /// Rebuild `tabs` by walking a desired top-level workspace order and
    /// emitting each workspace group as one contiguous run at its first
    /// encountered member.
    func normalizeWorkspaceGroupRunsPreservingOrder(_ desiredIds: [UUID]) {
        // Repair the anchor phase at the same boundary that repairs group
        // membership. This covers restore/import paths that assign `groupId`
        // directly instead of going through `assignGroup`.
        for index in workspaceGroups.indices {
            let groupId = workspaceGroups[index].id
            let members = tabs.filter { $0.groupId == groupId }
            if let liveAnchor = workspaceGroups[index].liveAnchorWorkspaceId,
               members.contains(where: { $0.id == liveAnchor }) {
                continue
            }
            if let firstMember = members.first {
                workspaceGroups[index].anchor = .workspace(firstMember.id)
            } else if !workspaceGroups[index].isPinned,
                      workspaceGroups[index].isEmpty == false {
                // Unpinned empty groups are not created by normal close paths,
                // but keeping their identity coherent makes malformed/imported
                // state deterministic until the caller explicitly removes it.
                workspaceGroups[index].anchor = .empty(workspaceGroups[index].id)
            }
        }
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
        let pinnedTopLevelIds = preferredTopLevelIds == nil
            ? sidebarTopLevelPinnedWorkspaceIds()
            : sidebarTopLevelPinnedWorkspaceIdsIncludingEmptyGroups()
        let desiredIds = topLevelIds.filter { pinnedTopLevelIds.contains($0) }
            + topLevelIds.filter { !pinnedTopLevelIds.contains($0) }
        // Always reassign so SwiftUI consumers re-evaluate row modifiers that
        // depend on `Workspace.groupId` even when the array contents are
        // unchanged.
        normalizeWorkspaceGroupRunsPreservingOrder(desiredIds)
        syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: preferredTopLevelIds)
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
    func syncWorkspaceGroupsOrderToAnchorOrder(preferredTopLevelIds: [UUID]? = nil) {
        if let preferredTopLevelIds {
            let groupsByAnchorId = Dictionary(
                uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) }
            )
            var orderedGroups: [WorkspaceGroup] = []
            var emittedGroupIds = Set<UUID>()
            for id in preferredTopLevelIds {
                guard let group = groupsByAnchorId[id], emittedGroupIds.insert(group.id).inserted else {
                    continue
                }
                orderedGroups.append(group)
            }
            orderedGroups.append(contentsOf: workspaceGroups.filter {
                !emittedGroupIds.contains($0.id)
            })
            workspaceGroups = orderedGroups
            return
        }
        let anchorIndex: [UUID: Int] = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        guard workspaceGroups.contains(where: { $0.liveAnchorWorkspaceId != nil }) else { return }
        // Empty groups have no tab index. Keep their existing group slots while
        // projecting live groups into the anchor order, so closing an anchor
        // does not silently move a surviving header past its group neighbors.
        let liveGroups = workspaceGroups
            .filter { $0.liveAnchorWorkspaceId != nil }
            .sorted { lhs, rhs in
                let l = lhs.liveAnchorWorkspaceId.flatMap { anchorIndex[$0] } ?? Int.max
                let r = rhs.liveAnchorWorkspaceId.flatMap { anchorIndex[$0] } ?? Int.max
                return l < r
            }
        var liveIndex = 0
        workspaceGroups = workspaceGroups.map { group in
            guard !group.isEmpty, liveGroups.indices.contains(liveIndex) else { return group }
            defer { liveIndex += 1 }
            return liveGroups[liveIndex]
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

    /// Applies the detach-path lifecycle for groups anchored by a removed
    /// workspace. Unpinned groups dissolve as before; pinned groups retain
    /// their membership, promote a remaining member, or become an empty group.
    /// Caller is responsible for having already removed the workspace from
    /// `tabs`.
    public func dissolveGroupsAnchoredBy(closedWorkspaceId: UUID) {
        let affectedGroups = workspaceGroups
            .filter { $0.anchorWorkspaceId == closedWorkspaceId }
        guard !affectedGroups.isEmpty else { return }
        let dissolvedGroupIds = affectedGroups.filter { !$0.isPinned }.map(\.id)
        for group in affectedGroups where group.isPinned {
            guard let groupIndex = workspaceGroups.firstIndex(where: { $0.id == group.id }) else { continue }
            if let nextAnchor = tabs.first(where: { $0.groupId == group.id }) {
                workspaceGroups[groupIndex].anchor = .workspace(nextAnchor.id)
            } else {
                workspaceGroups[groupIndex].anchor = .empty(group.id)
            }
        }
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

    /// Close-path group fixup for when `closedWorkspaceId` was a group anchor.
    ///
    /// Unlike `dissolveGroupsAnchoredBy` (used by the cross-window detach
    /// path), closing a workspace affects only that one workspace: the group
    /// survives by promoting its earliest remaining member (in `tabs` order)
    /// to be the new anchor. A pinned group with no members transitions to an
    /// empty anchor; an unpinned group is removed. Caller is responsible for
    /// having already removed the closed workspace from `tabs`.
    ///
    /// Returns the workspace ids promoted to anchor. A promoted workspace's
    /// resolved display title switches from its own title to the group name,
    /// so the caller must invalidate any imperatively-cached title chrome
    /// (window title, toolbar label) for a promoted anchor that is selected.
    @discardableResult
    public func promoteAnchorOrRemoveGroupsAnchoredBy(closedWorkspaceId: UUID) -> [UUID] {
        let affectedGroupIds = workspaceGroups
            .filter { $0.anchorWorkspaceId == closedWorkspaceId }
            .map(\.id)
        guard !affectedGroupIds.isEmpty else { return [] }
        var promotedAnchorIds: [UUID] = []
        var removedGroupIds: [UUID] = []
        for gid in affectedGroupIds {
            guard let groupIndex = workspaceGroups.firstIndex(where: { $0.id == gid }) else { continue }
            if let nextAnchor = tabs.first(where: { $0.groupId == gid }) {
                workspaceGroups[groupIndex].anchor = .workspace(nextAnchor.id)
                promotedAnchorIds.append(nextAnchor.id)
            } else if workspaceGroups[groupIndex].isPinned {
                workspaceGroups[groupIndex].anchor = .empty(workspaceGroups[groupIndex].id)
            } else {
                removedGroupIds.append(gid)
            }
        }
        if !removedGroupIds.isEmpty {
            workspaceGroups.removeAll { removedGroupIds.contains($0.id) }
        }
        // Hoist each promoted anchor to the front of its members so the sidebar
        // header renders at the anchor's row (parity with setWorkspaceGroupAnchor).
        normalizeWorkspaceGroupContiguity()
        return promotedAnchorIds
    }
}
