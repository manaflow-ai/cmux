import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

extension WorkspaceShellView {
    #if os(iOS)
    var submitTaskComposerFromShell: @MainActor (
        String,
        MobileWorkspaceCreateSpec,
        @escaping @MainActor () -> Void
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let store = store
        return { macDeviceID, spec, composerWillStartCreate in
            pendingCompactCreateNavigationWorkspaceIDs = nil
            var existingWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
            let result = await store.submitTaskComposer(
                macDeviceID: macDeviceID,
                spec: spec,
                willStartCreate: {
                    composerWillStartCreate()
                    guard usesCompactStack else { return }
                    let targetWorkspaceIDs = Set(store.workspaces.map(\.id))
                    existingWorkspaceIDs = targetWorkspaceIDs
                    pendingCompactCreateNavigationWorkspaceIDs = targetWorkspaceIDs
                }
            )
            if usesCompactStack, let existingWorkspaceIDs {
                settlePendingCompactCreateNavigation(
                    result: result,
                    existingWorkspaceIDs: existingWorkspaceIDs
                )
            } else {
                pendingCompactCreateNavigationWorkspaceIDs = nil
            }
            return result
        }
    }
    #endif

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
        _ beforeWorkspaceID: MobileWorkspacePreview.ID?,
        _ movesGroup: Bool
    ) async -> Bool)? {
        let store = store
        return { id, groupID, beforeWorkspaceID, movesGroup in
            let result = await store.moveWorkspace(
                id: id,
                toGroup: groupID,
                before: beforeWorkspaceID,
                movesGroup: movesGroup
            )
            await MainActor.run {
                handleWorkspaceActionResult(result, action: .moveWorkspace)
            }
            if case .success = result {
                return true
            }
            return false
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
        guard store.supportsWorkspaceCreateInGroup else { return nil }
        return { groupID in createWorkspaceInCompactStack(inGroup: groupID) }
    }

    var createWorkspaceInGroupIfConnectedClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard store.supportsWorkspaceCreateInGroup else { return nil }
        return { groupID in createWorkspaceIfConnected(inGroup: groupID) }
    }

    var createWorkspaceGroupInCompactStackClosure: (() -> Void)? {
        guard store.supportsWorkspaceGroupCreate else { return nil }
        return { createWorkspaceGroupIfConnected() }
    }

    var createWorkspaceGroupIfConnectedClosure: (() -> Void)? {
        guard store.supportsWorkspaceGroupCreate else { return nil }
        return { createWorkspaceGroupIfConnected() }
    }

    func createWorkspaceInCompactStack() {
        createWorkspaceInCompactStack(inGroup: nil)
    }

    func createWorkspaceInCompactStack(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        if store.usesLocalWorkspaceCreationFallback {
            store.createWorkspace(inGroup: groupID)
            settlePendingCompactCreateNavigation(
                result: .success(()),
                existingWorkspaceIDs: existingWorkspaceIDs
            )
            return
        }
        Task { @MainActor in
            let result = await store.createWorkspaceRequest(inGroup: groupID)
            handleWorkspaceActionResult(
                result,
                action: groupID == nil ? .createWorkspace : .createWorkspaceInGroup
            )
            settlePendingCompactCreateNavigation(
                result: result,
                existingWorkspaceIDs: existingWorkspaceIDs
            )
        }
    }

    func createWorkspaceIfConnected() {
        createWorkspaceIfConnected(inGroup: nil)
    }

    func createWorkspaceIfConnected(inGroup groupID: MobileWorkspaceGroupPreview.ID?) {
        guard canCreateWorkspaceForMacSelection else { return }
        if store.usesLocalWorkspaceCreationFallback {
            store.createWorkspace(inGroup: groupID)
            return
        }
        Task { @MainActor in
            let result = await store.createWorkspaceRequest(inGroup: groupID)
            handleWorkspaceActionResult(
                result,
                action: groupID == nil ? .createWorkspace : .createWorkspaceInGroup
            )
        }
    }

    func createWorkspaceGroupIfConnected() {
        guard canCreateWorkspaceForMacSelection else { return }
        Task { @MainActor in
            let result = await store.createWorkspaceGroup()
            handleWorkspaceActionResult(result, action: .createWorkspaceGroup)
        }
    }

    func settlePendingCompactCreateNavigation(
        result: Result<Void, MobileWorkspaceMutationFailure>,
        existingWorkspaceIDs: Set<MobileWorkspacePreview.ID>
    ) {
        let succeeded = if case .success = result { true } else { false }
        if let createdPath = compactNavigationPolicy.pathForCompletedCreate(
            currentPath: compactNavigationPath,
            selectedWorkspaceID: store.selectedWorkspaceID,
            existingWorkspaceIDs: existingWorkspaceIDs,
            succeeded: succeeded
        ) {
            pendingCompactCreateNavigationWorkspaceIDs = nil
            compactNavigationPath = createdPath
        } else {
            pendingCompactCreateNavigationWorkspaceIDs = nil
        }
    }
}
