import CmuxMobileShellModel

/// The workspace and route mode that determine a remote detail-open task.
struct WorkspaceDetailOpenTaskID: Hashable {
    let workspaceID: MobileWorkspacePreview.ID
    let openMode: WorkspaceDetailOpenMode
}
