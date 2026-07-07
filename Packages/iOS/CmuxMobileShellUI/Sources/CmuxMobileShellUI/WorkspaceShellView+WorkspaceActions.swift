import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

extension WorkspaceShellView {
    /// Workspace action closures, always present for the real store. Row and
    /// detail affordances gate themselves on each workspace's owning-Mac
    /// capability snapshot, so a secondary Mac is not hidden behind the
    /// foreground Mac's advertised capabilities.
    var renameWorkspaceClosure: ((MobileWorkspacePreview.ID, String) -> Void)? {
        let store = store
        return { id, title in
            Task { @MainActor in
                let result = await store.renameWorkspace(id: id, title: title)
                handleWorkspaceActionResult(result, action: .renameWorkspace)
            }
        }
    }

    var setWorkspacePinnedClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, pinned in
            Task { @MainActor in
                let result = await store.setWorkspacePinned(id: id, pinned)
                handleWorkspaceActionResult(
                    result,
                    action: pinned ? .pinWorkspace : .unpinWorkspace
                )
            }
        }
    }

    var setWorkspaceUnreadClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, unread in
            Task { @MainActor in
                let result = await store.setWorkspaceUnread(id: id, unread)
                handleWorkspaceActionResult(
                    result,
                    action: unread ? .markWorkspaceUnread : .markWorkspaceRead
                )
            }
        }
    }

    var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        let store = store
        return { id in
            Task { @MainActor in
                let result = await store.closeWorkspace(id: id)
                handleWorkspaceActionResult(result, action: .closeWorkspace)
            }
        }
    }

    var moveWorkspaceClosure: ((
        _ id: MobileWorkspacePreview.ID,
        _ groupID: MobileWorkspaceGroupPreview.ID?,
        _ beforeWorkspaceID: MobileWorkspacePreview.ID?
    ) async -> Void)? {
        let store = store
        return { id, groupID, beforeWorkspaceID in
            let result = await store.moveWorkspace(id: id, toGroup: groupID, before: beforeWorkspaceID)
            await MainActor.run {
                handleWorkspaceActionResult(result, action: .moveWorkspace)
            }
        }
    }

    var renameWorkspaceGroupClosure: ((MobileWorkspaceGroupPreview.ID, String) -> Void)? {
        let store = store
        return { id, title in
            Task { @MainActor in
                let result = await store.renameWorkspaceGroup(id: id, title: title)
                handleWorkspaceActionResult(result, action: .renameGroup)
            }
        }
    }

    var setWorkspaceGroupPinnedClosure: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? {
        let store = store
        return { id, pinned in
            Task { @MainActor in
                let result = await store.setWorkspaceGroupPinned(id: id, pinned)
                handleWorkspaceActionResult(
                    result,
                    action: pinned ? .pinGroup : .unpinGroup
                )
            }
        }
    }

    var ungroupWorkspaceGroupClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        let store = store
        return { id in
            Task { @MainActor in
                let result = await store.ungroupWorkspaceGroup(id: id)
                handleWorkspaceActionResult(result, action: .ungroupGroup)
            }
        }
    }

    var deleteWorkspaceGroupClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        let store = store
        return { id in
            Task { @MainActor in
                let result = await store.deleteWorkspaceGroup(id: id)
                handleWorkspaceActionResult(result, action: .deleteGroup)
            }
        }
    }

    /// Group collapse/expand closure. Present when the Mac advertises
    /// `workspace.groups.v1` or has actually emitted group sections.
    var toggleGroupCollapsedClosure: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? {
        guard store.supportsWorkspaceGroups || !store.workspaceGroups.isEmpty else { return nil }
        let store = store
        return { id, collapsed in Task { await store.setWorkspaceGroupCollapsed(id: id, collapsed) } }
    }

    var createWorkspaceInGroupInCompactStackClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        return { groupID in createWorkspaceInCompactStack(inGroup: groupID) }
    }

    var createWorkspaceInGroupIfConnectedClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        return { groupID in createWorkspaceIfConnected(inGroup: groupID) }
    }

    func createWorkspaceInCompactStack() {
        createWorkspaceInCompactStack(inGroup: nil)
    }

    func createWorkspaceInCompactStack(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        Task { @MainActor in
            let result = await store.createWorkspaceRequest(inGroup: groupID)
            handleWorkspaceActionResult(
                result,
                action: groupID == nil ? .createWorkspace : .createWorkspaceInGroup
            )
            if case .failure = result {
                pendingCompactCreateNavigationWorkspaceIDs = nil
            }
            if let createdPath = compactNavigationPolicy.pathForCreatedWorkspaceSelection(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: store.selectedWorkspaceID,
                existingWorkspaceIDs: existingWorkspaceIDs
            ) {
                pendingCompactCreateNavigationWorkspaceIDs = nil
                compactNavigationPath = createdPath
            }
        }
    }

    func createWorkspaceIfConnected() {
        createWorkspaceIfConnected(inGroup: nil)
    }

    func createWorkspaceIfConnected(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        Task { @MainActor in
            let result = await store.createWorkspaceRequest(inGroup: groupID)
            handleWorkspaceActionResult(
                result,
                action: groupID == nil ? .createWorkspace : .createWorkspaceInGroup
            )
        }
    }
}
