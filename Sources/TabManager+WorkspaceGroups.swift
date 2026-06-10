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


// MARK: - Workspace Groups
extension TabManager {
    /// Create a new group, inserting a fresh anchor workspace above the given
    /// child workspaces. Returns the new group id.
    ///
    /// The anchor is always brand new (never promoted from an existing
    /// workspace). Its cwd defaults to `anchorWorkingDirectory`, or the first
    /// eligible child's cwd, or whatever `addWorkspace` resolves on its own.
    @discardableResult
    func createWorkspaceGroup(
        name: String,
        childWorkspaceIds: [UUID] = [],
        anchorWorkingDirectory: String? = nil,
        selectAnchor: Bool = true,
        collapseSidebarSelection: Bool = true
    ) -> UUID? {
        // Eligible children: not currently an anchor of a different group.
        // Pulling an anchor into a new group would orphan the
        // source group (its anchorWorkspaceId would no longer match), so we
        // reject those silently and let the user explicitly ungroup first.
        let existingAnchorIds = Set(workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleChildren = childWorkspaceIds.compactMap { id -> UUID? in
            guard tabs.contains(where: { $0.id == id }),
                  !existingAnchorIds.contains(id) else { return nil }
            return id
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty
            ? nextAutoWorkspaceGroupName()
            : trimmedName

        let firstChildTab = eligibleChildren.first.flatMap { firstId in
            tabs.first(where: { $0.id == firstId })
        }
        let inferredCwd: String? = anchorWorkingDirectory
            ?? firstChildTab?.currentDirectory
        let originalTabOrder = tabs.map(\.id)

        let anchor = addWorkspace(
            title: resolvedName,
            workingDirectory: inferredCwd,
            inheritWorkingDirectory: inferredCwd == nil,
            select: selectAnchor,
            placementOverride: .top,
            autoWelcomeIfNeeded: false,
            normalizeWorkspaceGroupsAfterInsert: false
        )

        let group = WorkspaceGroup(
            id: UUID(),
            name: resolvedName,
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchor.id,
            customColor: nil,
            iconSymbol: nil
        )
        workspaceGroups.append(group)
        anchor.groupId = group.id
        for id in eligibleChildren {
            assignGroup(workspaceId: id, groupId: group.id)
        }
        placeNewWorkspaceGroupAtCreationPosition(
            groupId: group.id,
            anchorId: anchor.id,
            childWorkspaceIds: eligibleChildren,
            originalTabOrder: originalTabOrder
        )
        // Collapse the sidebar multi-selection so a second ⌘⇧G press doesn't
        // immediately reuse the same child ids and create a duplicate group
        // around them. The new anchor is the only sensible "current"
        // selection at this point. Posts the hide notification so the
        // SwiftUI sidebar binding follows.
        //
        // Skipped for the non-focus socket/CLI path (caller passes
        // collapseSidebarSelection: false): per the socket focus policy in
        // CLAUDE.md, those entrypoints must not mutate the user's active
        // sidebar selection.
        if collapseSidebarSelection,
           !sidebarSelectedWorkspaceIds.isDisjoint(with: Set(eligibleChildren)) || sidebarSelectedWorkspaceIds.count > 1 {
            let hiddenIds = sidebarSelectedWorkspaceIds
            sidebarSelectedWorkspaceIds = [anchor.id]
            NotificationCenter.default.post(
                name: .sidebarMultiSelectionDidHide,
                object: self,
                userInfo: [
                    SidebarMultiSelectionHideKey.hiddenWorkspaceIds: hiddenIds,
                    SidebarMultiSelectionHideKey.focusedWorkspaceId: anchor.id,
                ]
            )
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: [anchor.id] + eligibleChildren)
        return group.id
    }

    /// Create a brand-new workspace inheriting the anchor's cwd, attach it
    /// to the group, and position it within the group's tabs[] range per
    /// `placement`. Returns the new workspace.
    @discardableResult
    func createWorkspaceInGroup(
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement = WorkspaceGroupNewWorkspacePlacementSettings.resolved(),
        referenceWorkspaceId: UUID? = nil,
        select: Bool = true
    ) -> Workspace? {
        guard let group = workspaceGroups.first(where: { $0.id == groupId }) else { return nil }
        let cwd = tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
        let newWorkspace = addWorkspace(
            workingDirectory: cwd,
            inheritWorkingDirectory: cwd == nil,
            select: select,
            autoWelcomeIfNeeded: false
        )
        assignGroup(workspaceId: newWorkspace.id, groupId: groupId)
        placeWithinGroup(
            workspaceId: newWorkspace.id,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
        // Expand the group when the new workspace is being focused. The
        // selectedTabId auto-expand hook fires inside `addWorkspace` BEFORE
        // assignGroup, so it can't see the new workspace's membership. Without
        // this, clicking `+` on a collapsed group selects a workspace that's
        // visually hidden in the sidebar.
        if select,
           let idx = workspaceGroups.firstIndex(where: { $0.id == groupId }),
           workspaceGroups[idx].isCollapsed {
            workspaceGroups[idx].isCollapsed = false
        }
        normalizeWorkspaceGroupContiguity()
        postWorkspaceOrderDidChange(movedWorkspaceIds: [newWorkspace.id])
        return newWorkspace
    }

    /// Move an existing group member to the requested in-group slot. Called
    /// after `createWorkspaceInGroup` and any other path that needs to
    /// pin the new member relative to the group's members.
    private func placeWithinGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID? = nil
    ) {
        guard let group = workspaceGroups.first(where: { $0.id == groupId }),
              let currentIndex = tabs.firstIndex(where: { $0.id == workspaceId }) else { return }
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId && tabs[$0].id != workspaceId }
        func logMissingPlacementAnchor(_ placementName: String) {
            tabManagerLogger.info(
                "workspaceGroup.placeWithinGroup missing placement anchor group=\(groupId.uuidString, privacy: .public) workspace=\(workspaceId.uuidString, privacy: .public) placement=\(placementName, privacy: .public)"
            )
        }
        let targetIndex: Int
        switch placement {
        case .afterCurrent:
            if let referenceWorkspaceId,
               referenceWorkspaceId != workspaceId,
               let referenceIndex = tabs.firstIndex(where: { $0.id == referenceWorkspaceId && $0.groupId == groupId }) {
                targetIndex = referenceIndex + 1
            } else if let anchorIndex = tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                targetIndex = anchorIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                logMissingPlacementAnchor("afterCurrent")
                return
            }
        case .top:
            if let anchorIndex = tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                // Right after the anchor; the anchor stays first via
                // `normalizeWorkspaceGroupContiguity`'s anchorFirst pass.
                targetIndex = anchorIndex + 1
            } else if let firstMember = memberIndices.first {
                targetIndex = firstMember
            } else {
                logMissingPlacementAnchor("top")
                return
            }
        case .end:
            if let lastMember = memberIndices.last {
                targetIndex = lastMember + 1
            } else {
                // Only the anchor and the new workspace exist; treat as top.
                if let anchorIndex = tabs.firstIndex(where: { $0.id == group.anchorWorkspaceId }) {
                    targetIndex = anchorIndex + 1
                } else {
                    logMissingPlacementAnchor("end")
                    return
                }
            }
        }
        guard currentIndex != targetIndex else { return }
        let workspace = tabs.remove(at: currentIndex)
        let insertAt = currentIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(workspace, at: max(0, min(insertAt, tabs.count)))
    }

    /// Add an existing workspace to an existing group as a non-anchor member.
    /// No-op for workspaces that are the anchor of a different group (those
    /// must be ungrouped first to avoid orphaning the
    /// source group). If the workspace is the currently selected one and the
    /// target group is collapsed, the group auto-expands so the focused
    /// workspace stays visible.
    func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil
    ) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }) else { return }
        guard workspaceGroups.contains(where: { $0.id == groupId }) else { return }
        guard tab.groupId != groupId else { return }
        let isAnchorOfOtherGroup = workspaceGroups.contains { group in
            group.id != groupId && group.anchorWorkspaceId == workspaceId
        }
        if isAnchorOfOtherGroup { return }
        let originalTopLevelIds = sidebarTopLevelWorkspaceIds()
        assignGroup(workspaceId: workspaceId, groupId: groupId)
        // selectedTabId may not change here (the workspace was already
        // selected), so the existing didSet hook won't fire. Expand manually
        // when the added workspace is the focused one so it doesn't end up
        // hidden inside a collapsed section.
        if selectedTabId == workspaceId,
           let groupIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }),
           workspaceGroups[groupIndex].isCollapsed {
            workspaceGroups[groupIndex].isCollapsed = false
        }
        normalizeWorkspaceGroupContiguity(
            preservingTopLevelIds: originalTopLevelIds.filter { $0 != workspaceId }
        )
        if let placement {
            placeWithinGroup(
                workspaceId: workspaceId,
                groupId: groupId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
        }
        postWorkspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Remove a non-anchor workspace from its group. If the workspace is its
    /// group's anchor, the group is dissolved instead (other members survive
    /// as ungrouped workspaces).
    func removeWorkspaceFromGroup(workspaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == workspaceId }),
              let groupId = tab.groupId else { return }
        if let group = workspaceGroups.first(where: { $0.id == groupId }),
           group.anchorWorkspaceId == workspaceId {
            ungroupWorkspaceGroup(groupId: groupId)
            return
        }
        assignGroup(workspaceId: workspaceId, groupId: nil)
        normalizeWorkspaceGroupContiguity()
        postWorkspaceOrderDidChange(movedWorkspaceIds: [workspaceId])
    }

    /// Dissolve a group while preserving every member workspace (including its
    /// anchor) as a regular ungrouped workspace. Nothing is closed. The
    /// former members KEEP their `tabs[]` positions so the anchor — which
    /// was previously rendered exclusively as the group header — appears as
    /// a workspace row at the same vertical spot the header occupied, with
    /// the rest of the members staying right below it in their existing
    /// relative order. We deliberately do not re-normalize here: that would
    /// push the now-ungrouped members down into the "ungrouped tier at the
    /// bottom" slot, which makes Ungroup feel like a destructive move
    /// instead of a flatten-in-place.
    func ungroupWorkspaceGroup(groupId: UUID) {
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        guard !memberIds.isEmpty || workspaceGroups.contains(where: { $0.id == groupId }) else { return }
        for id in memberIds {
            assignGroup(workspaceId: id, groupId: nil)
        }
        workspaceGroups.removeAll { $0.id == groupId }
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    /// Delete a group and close every workspace inside it (anchor + all
    /// members). This is the destructive sibling of
    /// `ungroupWorkspaceGroup`: ungroup keeps the workspaces, delete throws
    /// them away. Callers that need confirmation must prompt before calling
    /// this; the method itself is unconditional so socket/CLI paths can opt
    /// out of the prompt cleanly.
    @discardableResult
    func deleteWorkspaceGroup(groupId: UUID, recordHistory: Bool = true) -> Int {
        guard workspaceGroups.contains(where: { $0.id == groupId }) else { return 0 }
        let members = tabs.filter { $0.groupId == groupId }
        var closed = 0
        for tab in members {
            // closeWorkspace short-circuits when tabs.count <= 1, so the last
            // remaining workspace would be left alive with a stale groupId.
            // Convert the holdout into a regular workspace (clear groupId)
            // instead, and let the caller's surrounding flow decide whether
            // to close the window. We still report it in the count of items
            // "removed from the group" so the response is accurate.
            if tabs.count <= 1 {
                assignGroup(workspaceId: tab.id, groupId: nil)
                continue
            }
            let countBefore = tabs.count
            closeWorkspace(tab, recordHistory: recordHistory)
            if tabs.count < countBefore { closed += 1 }
        }
        // closeWorkspace's dissolveGroupsAnchoredBy already removes the group
        // when the anchor is among the closed members, but if every member
        // was non-anchor (callers can construct that shape via socket
        // workspace.group.set_anchor races) the group survives — clean up.
        workspaceGroups.removeAll { $0.id == groupId }
        return closed
    }

    /// Rename a group. Whitespace-only names are ignored.
    func renameWorkspaceGroup(groupId: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].name != trimmed else { return }
        workspaceGroups[index].name = trimmed
        // The group's name is the single source of truth for its anchor's
        // displayed title (see `resolvedWorkspaceDisplayTitle(for:)`). The
        // sidebar re-reads `group.name` via the @Published array, but the
        // imperatively-cached window-chrome surfaces (custom title bar,
        // toolbar command label) need an explicit nudge, and NSWindow.title
        // is refreshed inline here.
        updateWindowTitleForSelectedTab()
        NotificationCenter.default.post(name: .workspaceGroupNameDidChange, object: self)
    }

    /// UI-only collapse toggle: also moves focus to the anchor if the
    /// currently-selected workspace is a non-anchor child that would be
    /// hidden by the collapse. The pure-data variant
    /// `setWorkspaceGroupCollapsed` is the right call for socket/CLI paths
    /// that must preserve focus (the socket focus policy in CLAUDE.md).
    func toggleWorkspaceGroupCollapsed(groupId: UUID) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let nextCollapsed = !workspaceGroups[index].isCollapsed
        if nextCollapsed {
            let anchorId = workspaceGroups[index].anchorWorkspaceId
            if let selectedTabId,
               selectedTabId != anchorId,
               let selectedTab = tabs.first(where: { $0.id == selectedTabId }),
               selectedTab.groupId == groupId,
               let anchor = tabs.first(where: { $0.id == anchorId }) {
                selectWorkspace(anchor)
            }
            // Strip any sidebar multi-selection entries that point at
            // now-hidden non-anchor children of this group. Without this, a
            // close/group shortcut fired after the collapse would still act
            // on workspaces the user can no longer see.
            let hiddenMemberIds: Set<UUID> = Set(
                tabs
                    .filter { $0.groupId == groupId && $0.id != anchorId }
                    .map(\.id)
            )
            if !hiddenMemberIds.isEmpty,
               !sidebarSelectedWorkspaceIds.isDisjoint(with: hiddenMemberIds) {
                sidebarSelectedWorkspaceIds.subtract(hiddenMemberIds)
                // Use the "did hide" notification (not collapse-to-one) so the
                // SwiftUI sidebar only strips the hidden ids and keeps any
                // visible multi-selection entries that sit outside the group.
                var userInfo: [AnyHashable: Any] = [
                    SidebarMultiSelectionHideKey.hiddenWorkspaceIds: hiddenMemberIds
                ]
                if let selectedTabId, selectedTabId == anchorId {
                    userInfo[SidebarMultiSelectionHideKey.focusedWorkspaceId] = anchorId
                }
                NotificationCenter.default.post(
                    name: .sidebarMultiSelectionDidHide,
                    object: self,
                    userInfo: userInfo
                )
            }
        }
        setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: nextCollapsed)
    }

    /// Pure data mutation — flips the collapse flag without touching
    /// selection. Use this from socket/CLI handlers so a non-focus-intent
    /// command never steals the user's active workspace.
    func setWorkspaceGroupCollapsed(groupId: UUID, isCollapsed: Bool) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].isCollapsed != isCollapsed else { return }
        workspaceGroups[index].isCollapsed = isCollapsed
    }

    /// Toggle the pinned state of a whole group. Pinned groups float above
    /// unpinned groups in the sidebar. Independent of per-workspace pin.
    func toggleWorkspaceGroupPinned(groupId: UUID) {
        setWorkspaceGroupPinned(groupId: groupId, isPinned: !(workspaceGroups.first(where: { $0.id == groupId })?.isPinned ?? false))
    }

    func setWorkspaceGroupPinned(groupId: UUID, isPinned: Bool) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].isPinned != isPinned else { return }
        workspaceGroups[index].isPinned = isPinned
        normalizeWorkspaceGroupContiguity()
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    func setWorkspaceGroupColor(groupId: UUID, hex: String?) {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard workspaceGroups[index].customColor != hex else { return }
        workspaceGroups[index].customColor = hex
    }

    @discardableResult
    func setWorkspaceGroupIcon(groupId: UUID, symbol: String?) -> String? {
        let normalized = RenderableSystemSymbol.normalized(symbol)
        guard let index = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return nil }
        guard workspaceGroups[index].iconSymbol != normalized else { return normalized }
        workspaceGroups[index].iconSymbol = normalized
        return normalized
    }

    /// Reassign which member workspace serves as the group's anchor.
    /// `workspaceId` must already be a member of the group.
    func setWorkspaceGroupAnchor(groupId: UUID, workspaceId: UUID) {
        guard let groupIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard let tab = tabs.first(where: { $0.id == workspaceId }), tab.groupId == groupId else { return }
        guard workspaceGroups[groupIndex].anchorWorkspaceId != workspaceId else { return }
        workspaceGroups[groupIndex].anchorWorkspaceId = workspaceId
        // Hoist the new anchor to the front of its members in tabs[] so the
        // sidebar header is rendered at the anchor's position. Without this,
        // the header would still draw at the (former) first member but the
        // shortcut digit / focus target would point at the new anchor lower
        // down, breaking workspace-number navigation.
        normalizeWorkspaceGroupContiguity()
        // Publish the order change so CmuxEventBus subscribers and any
        // notification observers see the new anchor position immediately
        // (other group-mutation paths post; this one was a hole).
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds.isEmpty ? [workspaceId] : memberIds)
        _ = tab
    }

    /// Move a group to a new group-slot position. `targetIndex` is interpreted
    /// as the FINAL position the group should end up at in `workspaceGroups`
    /// (post-move). It is clamped to the range occupied by groups in the same
    /// pin tier as the source. Ungrouped top-level workspace rows keep their
    /// slots; the reordered group anchors are projected back into the existing
    /// group slots.
    func moveWorkspaceGroup(groupId: UUID, toIndex targetIndex: Int) {
        guard moveWorkspaceGroupSlot(groupId: groupId, toIndex: targetIndex) else { return }
        applyWorkspaceGroupSlotOrderToTabs()
        let memberIds = tabs.filter { $0.groupId == groupId }.map(\.id)
        postWorkspaceOrderDidChange(movedWorkspaceIds: memberIds)
    }

    @discardableResult
    private func moveWorkspaceGroupSlot(groupId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentIndex = workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return false }
        let isPinned = workspaceGroups[currentIndex].isPinned
        let sameTierIndices = workspaceGroups.indices.filter { workspaceGroups[$0].isPinned == isPinned }
        guard let firstSameTier = sameTierIndices.first,
              let lastSameTier = sameTierIndices.last else { return false }
        let clampedTarget = max(firstSameTier, min(targetIndex, lastSameTier))
        guard clampedTarget != currentIndex else { return false }
        let group = workspaceGroups.remove(at: currentIndex)
        // Insert at clampedTarget directly — the source's removal already
        // shifted subsequent indices down, so for a desired final position
        // of N: if N < currentIndex, indices to the left didn't move (insert
        // at N); if N > currentIndex, the source's removal shifted N's old
        // contents left by one, but we want our group AT position N in the
        // final array, which means inserting after that element — index N
        // works because we're inserting into a shorter array.
        workspaceGroups.insert(group, at: max(0, min(clampedTarget, workspaceGroups.count)))
        return true
    }

    private func applyWorkspaceGroupSlotOrderToTabs() {
        let groupsByAnchorId = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.anchorWorkspaceId, $0) })
        let topLevelIds = sidebarTopLevelWorkspaceIds()
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })

        var pinnedTopLevelIds: [UUID] = []
        var unpinnedTopLevelIds: [UUID] = []
        pinnedTopLevelIds.reserveCapacity(topLevelIds.count)
        unpinnedTopLevelIds.reserveCapacity(topLevelIds.count)
        for id in topLevelIds {
            let isPinned = groupsByAnchorId[id]?.isPinned ?? (tabsById[id]?.isPinned == true)
            if isPinned {
                pinnedTopLevelIds.append(id)
            } else {
                unpinnedTopLevelIds.append(id)
            }
        }
        let tieredTopLevelIds = pinnedTopLevelIds + unpinnedTopLevelIds

        var pinnedAnchors: [UUID] = []
        var unpinnedAnchors: [UUID] = []
        pinnedAnchors.reserveCapacity(workspaceGroups.count)
        unpinnedAnchors.reserveCapacity(workspaceGroups.count)
        for group in workspaceGroups {
            if group.isPinned {
                pinnedAnchors.append(group.anchorWorkspaceId)
            } else {
                unpinnedAnchors.append(group.anchorWorkspaceId)
            }
        }
        var pinnedAnchorIndex = 0
        var unpinnedAnchorIndex = 0
        let desiredIds = tieredTopLevelIds.map { id -> UUID in
            guard let group = groupsByAnchorId[id] else { return id }
            if group.isPinned, pinnedAnchorIndex < pinnedAnchors.count {
                defer { pinnedAnchorIndex += 1 }
                return pinnedAnchors[pinnedAnchorIndex]
            }
            if !group.isPinned, unpinnedAnchorIndex < unpinnedAnchors.count {
                defer { unpinnedAnchorIndex += 1 }
                return unpinnedAnchors[unpinnedAnchorIndex]
            }
            return id
        }
        normalizeWorkspaceGroupRunsPreservingOrder(desiredIds)
        syncWorkspaceGroupsOrderToAnchorOrder()
    }

    /// Pick the next "Group N" name that doesn't collide with an existing
    /// group. Used when the user creates a group without naming it.
    private func nextAutoWorkspaceGroupName() -> String {
        let used = Set(workspaceGroups.map(\.name))
        var n = workspaceGroups.count + 1
        while true {
            let format = String(
                localized: "workspaceGroup.autoName.numbered",
                defaultValue: "Group %lld"
            )
            let candidate = String.localizedStringWithFormat(format, n)
            if !used.contains(candidate) { return candidate }
            n += 1
        }
    }

}
