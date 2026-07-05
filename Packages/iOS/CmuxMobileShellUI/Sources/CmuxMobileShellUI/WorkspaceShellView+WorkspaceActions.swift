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
        return { id, title in Task { await store.renameWorkspace(id: id, title: title) } }
    }

    var setWorkspacePinnedClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, pinned in Task { await store.setWorkspacePinned(id: id, pinned) } }
    }

    var setWorkspaceUnreadClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, unread in Task { await store.setWorkspaceUnread(id: id, unread) } }
    }

    var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        let store = store
        return { id in Task { await store.closeWorkspace(id: id) } }
    }

    var moveWorkspaceClosure: ((
        _ id: MobileWorkspacePreview.ID,
        _ groupID: MobileWorkspaceGroupPreview.ID?,
        _ beforeWorkspaceID: MobileWorkspacePreview.ID?
    ) -> Void)? {
        guard store.supportsWorkspaceActions else { return nil }
        let store = store
        return { id, groupID, beforeWorkspaceID in
            Task {
                await store.moveWorkspace(id: id, toGroup: groupID, before: beforeWorkspaceID)
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
        guard store.supportsWorkspaceGroups || !store.workspaceGroups.isEmpty else { return nil }
        return { groupID in createWorkspaceInCompactStack(inGroup: groupID) }
    }

    var createWorkspaceInGroupIfConnectedClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard store.supportsWorkspaceGroups || !store.workspaceGroups.isEmpty else { return nil }
        return { groupID in createWorkspaceIfConnected(inGroup: groupID) }
    }

    func createWorkspaceInCompactStack() {
        createWorkspaceInCompactStack(inGroup: nil)
    }

    func createWorkspaceInCompactStack(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        store.createWorkspace(inGroup: groupID)
        if let createdPath = compactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: compactNavigationPath,
            selectedWorkspaceID: store.selectedWorkspaceID,
            existingWorkspaceIDs: existingWorkspaceIDs
        ) {
            pendingCompactCreateNavigationWorkspaceIDs = nil
            compactNavigationPath = createdPath
        }
    }

    func createWorkspaceIfConnected() {
        createWorkspaceIfConnected(inGroup: nil)
    }

    func createWorkspaceIfConnected(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        store.createWorkspace(inGroup: groupID)
    }
}
