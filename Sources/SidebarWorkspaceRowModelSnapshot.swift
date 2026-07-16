import CmuxWorkspaces
import Foundation

/// Cheap immutable workspace facts used by the sidebar's lazy row projection.
///
/// The parent copies these values from each live `Workspace` before the
/// `LazyVStack`. Realized rows never retain or read the workspace model.
struct SidebarWorkspaceRowModelSnapshot {
    let workspaceId: UUID
    let groupId: UUID?
    let isPinned: Bool
    let hasUserCustomTitle: Bool
    let hasCustomTitle: Bool
    let hasCustomDescription: Bool
    let customTitle: String?
    let isRemoteContextMenuEligible: Bool
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let inferredTaskStatus: WorkspaceTaskStatus
    let activeTodoOverride: WorkspaceTaskStatus?
    let isTodoStatusHidden: Bool

    init(
        workspaceId: UUID,
        groupId: UUID?,
        isPinned: Bool,
        hasUserCustomTitle: Bool,
        hasCustomTitle: Bool,
        hasCustomDescription: Bool,
        customTitle: String?,
        isRemoteContextMenuEligible: Bool,
        remoteConnectionState: WorkspaceRemoteConnectionState,
        inferredTaskStatus: WorkspaceTaskStatus,
        activeTodoOverride: WorkspaceTaskStatus?,
        isTodoStatusHidden: Bool
    ) {
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isPinned = isPinned
        self.hasUserCustomTitle = hasUserCustomTitle
        self.hasCustomTitle = hasCustomTitle
        self.hasCustomDescription = hasCustomDescription
        self.customTitle = customTitle
        self.isRemoteContextMenuEligible = isRemoteContextMenuEligible
        self.remoteConnectionState = remoteConnectionState
        self.inferredTaskStatus = inferredTaskStatus
        self.activeTodoOverride = activeTodoOverride
        self.isTodoStatusHidden = isTodoStatusHidden
    }

    @MainActor
    init(workspace: Workspace) {
        workspaceId = workspace.id
        groupId = workspace.groupId
        isPinned = workspace.isPinned
        hasUserCustomTitle = workspace.effectiveCustomTitleSource == .user
        hasCustomTitle = workspace.hasCustomTitle
        hasCustomDescription = workspace.hasCustomDescription
        customTitle = workspace.customTitle
        isRemoteContextMenuEligible = workspace.isRemoteWorkspace
            && !workspace.isManagedCloudVMWorkspace
        remoteConnectionState = workspace.remoteConnectionState
        inferredTaskStatus = workspace.inferredTaskStatus
        isTodoStatusHidden = workspace.todoState.statusHidden

        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(
            override: workspace.todoState.statusOverride,
            inferred: workspace.inferredTaskStatus
        )
        if let override = workspace.todoState.statusOverride,
           !resolution.shouldClearOverride {
            activeTodoOverride = override.status
        } else {
            activeTodoOverride = nil
        }
    }
}
