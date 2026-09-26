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
            workspaceNotFound: String(
                localized: "socket.workspace.reorderMany.workspaceNotFound",
                defaultValue: "Workspace not found"
            ),
            invalidWorkspaceRef: String(
                localized: "socket.workspace.reorderMany.invalidWorkspace",
                defaultValue: "Invalid workspace id or ref"
            ),
            reorderIndexNotAnInteger: String(
                localized: "socket.workspace.reorder.indexNotAnInteger",
                defaultValue: "index must be an integer"
            ),
            reorderMissingWorkspaceID: String(
                localized: "socket.workspace.reorder.missingWorkspaceID",
                defaultValue: "Missing or invalid workspace_id"
            ),
            reorderTargetRequired: String(
                localized: "socket.workspace.reorder.targetRequired",
                defaultValue: "Specify exactly one target: index, before_workspace_id, or after_workspace_id"
            ),
            reorderManyTabManagerUnavailable: String(
                localized: "socket.workspace.reorderMany.tabManagerUnavailable",
                defaultValue: "TabManager not available"
            ),
            tabManagerUnavailable: String(
                localized: "socket.workspace.list.tabManagerUnavailable",
                defaultValue: "TabManager not available"
            ),
            relayOwnerUnavailable: String(
                localized: "socket.workspace.list.relayOwnerUnavailable",
                defaultValue: "Relay owner workspace is not active"
            ),
            reorderRejected: String(
                localized: "socket.workspace.reorder.rejected",
                defaultValue: "Workspace reorder placement was refused"
            )
        )
    }
}
