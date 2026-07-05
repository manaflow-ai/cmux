/// A native drag/drop landing target in the mobile workspace list.
public enum MobileWorkspaceDropTarget: Equatable, Sendable {
    /// Drop onto a group header, appending the workspace at the end of that group.
    case groupHeader(MobileWorkspaceGroupPreview.ID)
    /// Drop immediately before a workspace row.
    case beforeWorkspace(MobileWorkspacePreview.ID)
    /// Drop immediately after a workspace row.
    case afterWorkspace(MobileWorkspacePreview.ID)
}
