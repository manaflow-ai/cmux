import CmuxControlSocket
import Foundation

extension TerminalController {
    func controlWorkspaceStrings() -> ControlWorkspaceStrings {
        ControlWorkspaceStrings(
            closeProtected: String(
                localized: "workspace.closeProtected.message",
                defaultValue: "Pinned workspaces can't be closed while pinned. Unpin the workspace first."
            ),
            closeFailed: String(
                localized: "cli.socket.error.workspaceNotClosed",
                defaultValue: "Workspace not closed"
            ),
            reorderManyMissingOrder: String(
                localized: "socket.workspace.reorderMany.missingOrder",
                defaultValue: "Missing workspace_ids"
            ),
            reorderManyDuplicateWorkspace: String(
                localized: "socket.workspace.reorderMany.duplicateWorkspace",
                defaultValue: "Duplicate workspace in order"
            ),
            reorderManyWorkspaceNotFound: String(
                localized: "socket.workspace.reorderMany.workspaceNotFound",
                defaultValue: "Workspace not found"
            ),
            reorderManyInvalidWorkspace: String(
                localized: "socket.workspace.reorderMany.invalidWorkspace",
                defaultValue: "Invalid workspace id or ref"
            ),
            reorderManyTabManagerUnavailable: String(
                localized: "socket.workspace.reorderMany.tabManagerUnavailable",
                defaultValue: "TabManager not available"
            )
        )
    }
}
