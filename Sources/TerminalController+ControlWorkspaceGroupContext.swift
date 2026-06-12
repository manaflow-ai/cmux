import CmuxControlSocket
import CmuxWorkspaces
import Foundation
import CmuxSettings

/// The workspace-group-domain witnesses for the stage-3c
/// ``ControlCommandCoordinator``: the byte-faithful bodies of the former
/// `v2WorkspaceGroup*` dispatchers, minus the per-read `v2MainSync` hop (the
/// coordinator already runs on the main actor inside the socket-command policy
/// scope, so each hop would re-apply the identical thread-local focus-allowance
/// stack — a no-op). TabManager resolution goes through the shared
/// `resolveTabManager(routing:)`; app structs are converted to the package's
/// Sendable snapshots.
extension TerminalController: ControlWorkspaceGroupContext {
    func controlWorkspaceGroupStrings() -> ControlWorkspaceGroupStrings {
        ControlWorkspaceGroupStrings(
            allChildrenAreAnchors: String(
                localized: "workspaceGroup.error.allChildrenAreAnchors",
                defaultValue: "All requested children are ineligible because they are already group anchors; ungroup them first"
            ),
            workspaceIsOtherGroupAnchor: String(
                localized: "workspaceGroup.error.workspaceIsOtherGroupAnchor",
                defaultValue: "Workspace is the anchor of another group; ungroup it first"
            )
        )
    }

    /// Builds the Sendable snapshot of one group (the legacy
    /// `v2WorkspaceGroupPayload` data, minus the ref minting the coordinator now
    /// owns).
    private func controlWorkspaceGroupSnapshot(
        _ group: WorkspaceGroup,
        tabManager: TabManager
    ) -> ControlWorkspaceGroupSnapshot {
        let memberIds = tabManager.tabs.compactMap { $0.groupId == group.id ? $0.id : nil }
        return ControlWorkspaceGroupSnapshot(
            id: group.id,
            name: group.name,
            isCollapsed: group.isCollapsed,
            isPinned: group.isPinned,
            anchorWorkspaceID: group.anchorWorkspaceId,
            customColor: group.customColor,
            iconSymbol: group.iconSymbol,
            memberWorkspaceIDs: memberIds
        )
    }

    func controlWorkspaceGroupList(
        routing: ControlRoutingSelectors
    ) -> ControlWorkspaceGroupListResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let groups = tabManager.workspaceGroups.map {
            controlWorkspaceGroupSnapshot($0, tabManager: tabManager)
        }
        let windowId = AppDelegate.shared?.windowId(for: tabManager)
        return .resolved(windowID: windowId, groups: groups)
    }

    func controlCreateWorkspaceGroup(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        childWorkspaceIDs: [UUID],
        childrenExplicit: Bool
    ) -> ControlWorkspaceGroupCreateResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }

        // Default behavior when children were absent: group the active sidebar
        // selection, or fall back to the caller workspace_id, or the focused
        // workspace. (An explicit empty array still creates an anchor-only group.)
        let parsedChildIds: [UUID]
        if childrenExplicit {
            parsedChildIds = childWorkspaceIDs
        } else {
            let selected = tabManager.sidebarSelectedWorkspaceIds
            if !selected.isEmpty {
                parsedChildIds = tabManager.tabs.compactMap { selected.contains($0.id) ? $0.id : nil }
            } else if let callerId = routing.workspaceID,
                      tabManager.tabs.contains(where: { $0.id == callerId }) {
                parsedChildIds = [callerId]
            } else if let selectedId = tabManager.selectedTabId {
                parsedChildIds = [selectedId]
            } else {
                parsedChildIds = []
            }
        }

        // A syntactically valid UUID can still reference a workspace that doesn't
        // exist in this TabManager. Surface those instead of silently dropping
        // them into an anchor-only group.
        let knownTabIds = Set(tabManager.tabs.map(\.id))
        let missing: [String] = parsedChildIds.compactMap { id in
            knownTabIds.contains(id) ? nil : id.uuidString
        }
        if !missing.isEmpty {
            return .childWorkspaceNotFound(missing)
        }
        let childIds = parsedChildIds

        // When the caller explicitly listed children, refuse to create an
        // anchor-only group if every one of them was already an anchor of
        // another group.
        if childrenExplicit, !parsedChildIds.isEmpty {
            let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
            let ineligible: [String] = parsedChildIds.compactMap { id -> String? in
                guard tabManager.tabs.contains(where: { $0.id == id }) else { return nil }
                if existingAnchorIds.contains(id) {
                    return id.uuidString
                }
                return nil
            }
            if ineligible.count == parsedChildIds.count {
                return .allChildrenAreAnchors(ineligible)
            }
        }

        // workspace.group.create is NOT a focus-intent method; do not change the
        // user's active workspace.
        let createdGroupId = tabManager.createWorkspaceGroup(
            name: name,
            childWorkspaceIds: childIds,
            anchorWorkingDirectory: cwd,
            selectAnchor: false,
            collapseSidebarSelection: false
        )
        guard let gid = createdGroupId,
              let group = tabManager.workspaceGroups.first(where: { $0.id == gid }) else {
            return .notCreated
        }
        return .created(controlWorkspaceGroupSnapshot(group, tabManager: tabManager))
    }

    func controlUngroupWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let found = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if found {
            tabManager.ungroupWorkspaceGroup(groupId: groupID)
        }
        return found
    }

    func controlDeleteWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }) else { return -1 }
        return tabManager.deleteWorkspaceGroup(groupId: groupID)
    }

    func controlRenameWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        name: String
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.renameWorkspaceGroup(groupId: groupID, name: name) }
        return ok
    }

    func controlSetWorkspaceGroupCollapsed(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        isCollapsed: Bool
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.setWorkspaceGroupCollapsed(groupId: groupID, isCollapsed: isCollapsed) }
        return ok
    }

    func controlSetWorkspaceGroupPinned(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        isPinned: Bool
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.setWorkspaceGroupPinned(groupId: groupID, isPinned: isPinned) }
        return ok
    }

    func controlAddWorkspaceToGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID
    ) -> ControlWorkspaceGroupAddResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let hasGroup = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        guard let tab = tabManager.tabs.first(where: { $0.id == workspaceID }), hasGroup else {
            return .notFound
        }
        // addWorkspaceToGroup silently no-ops for anchors of other groups.
        // Confirm membership actually changed before reporting success.
        tabManager.addWorkspaceToGroup(workspaceId: workspaceID, groupId: groupID)
        if tab.groupId == groupID {
            return .added
        }
        if tabManager.workspaceGroups.contains(where: { $0.id != groupID && $0.anchorWorkspaceId == workspaceID }) {
            return .workspaceIsOtherGroupAnchor
        }
        return .notFound
    }

    func controlRemoveWorkspaceFromGroup(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        if let tab = tabManager.tabs.first(where: { $0.id == workspaceID }), tab.groupId != nil {
            tabManager.removeWorkspaceFromGroup(workspaceId: workspaceID)
            return true
        }
        return false
    }

    func controlSetWorkspaceGroupAnchor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let hasGroup = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        let hasWs = tabManager.tabs.contains(where: { $0.id == workspaceID && $0.groupId == groupID })
        if hasGroup && hasWs {
            tabManager.setWorkspaceGroupAnchor(groupId: groupID, workspaceId: workspaceID)
            return true
        }
        return false
    }

    func controlCreateWorkspaceInGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        placementRaw: String?
    ) -> ControlWorkspaceGroupNewWorkspaceResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        // Placement resolution: explicit `placement` param wins, then the group's
        // per-cwd `newWorkspacePlacement` from cmux.json, then the global default.
        let explicitPlacement = WorkspaceGroupNewPlacement(rawString: placementRaw)
        if let raw = placementRaw,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           explicitPlacement == nil {
            return .invalidPlacement(raw)
        }
        guard let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }) else {
            return .notFound
        }
        let anchorCwd = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
        let configStore = AppDelegate.shared?.mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.cmuxConfigStore
        let configured = configStore?.resolveWorkspaceGroupConfig(forCwd: anchorCwd)?.newWorkspacePlacement
        let placement = explicitPlacement
            ?? configured
            ?? UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
        guard let newWs = tabManager.createWorkspaceInGroup(
            groupId: groupID,
            placement: placement,
            select: false
        ) else {
            return .notFound
        }
        return .created(workspaceID: newWs.id)
    }

    func controlSetWorkspaceGroupColor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        hex: String?
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let ok = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        if ok { tabManager.setWorkspaceGroupColor(groupId: groupID, hex: hex) }
        return ok
    }

    func controlSetWorkspaceGroupIcon(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        symbol: String?
    ) -> (found: Bool, storedSymbol: String?)? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        let found = tabManager.workspaceGroups.contains(where: { $0.id == groupID })
        var storedIconSymbol: String?
        if found {
            storedIconSymbol = tabManager.setWorkspaceGroupIcon(groupId: groupID, symbol: symbol)
        }
        return (found, storedIconSymbol)
    }

    func controlMoveWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        toIndex: Int?,
        beforeGroupID: UUID?,
        afterGroupID: UUID?
    ) -> Bool? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard let current = tabManager.workspaceGroups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }
        // moveWorkspaceGroup interprets toIndex as the FINAL position the group
        // should occupy. before/after refer to a peer's CURRENT index, so when
        // the source comes before the peer in the original order, removing the
        // source shifts the peer left by one, and the translated final position
        // must shift with it.
        let target: Int? = {
            if let toIndex {
                return toIndex
            }
            if let beforeId = beforeGroupID,
               let beforeIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == beforeId }) {
                return current < beforeIndex ? beforeIndex - 1 : beforeIndex
            }
            if let afterId = afterGroupID,
               let afterIndex = tabManager.workspaceGroups.firstIndex(where: { $0.id == afterId }) {
                return current < afterIndex ? afterIndex : afterIndex + 1
            }
            return nil
        }()
        guard let target else { return false }
        tabManager.moveWorkspaceGroup(groupId: groupID, toIndex: target)
        return true
    }

    func controlFocusWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> ControlWorkspaceGroupFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let group = tabManager.workspaceGroups.first(where: { $0.id == groupID }),
              let anchor = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId }) else {
            return .notFound
        }
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        // Route through selectWorkspace so the explicit-resume notification
        // dismissal and other selection side effects fire, matching
        // workspace.select and the sidebar header click path.
        tabManager.selectWorkspace(anchor)
        return .focused(anchorWorkspaceID: anchor.id)
    }
}
