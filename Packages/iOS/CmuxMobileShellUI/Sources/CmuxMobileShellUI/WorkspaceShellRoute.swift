import CmuxMobileShellModel

/// One pushed level in the compact workspace navigation stack.
enum WorkspaceShellRoute: Hashable {
    case hub(workspaceID: MobileWorkspacePreview.ID)
    case pane(workspaceID: MobileWorkspacePreview.ID, paneID: String, surfaceID: String)

    var workspaceID: MobileWorkspacePreview.ID {
        switch self {
        case .hub(let workspaceID), .pane(let workspaceID, _, _):
            workspaceID
        }
    }
}
