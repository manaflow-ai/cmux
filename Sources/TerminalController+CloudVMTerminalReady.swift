import Foundation

extension TerminalController {
    /// The pane a Cloud attachment lands in: the workspace's loading card (deferred
    /// attachment, adopted later by the catalog) or the terminal that replaced it.
    struct CloudVMTerminalAttachment {
        let workspace: Workspace
        let panelID: UUID
    }

    enum CloudVMTerminalAttachmentError: Error, Equatable {
        case workspaceNotFound
        case emptyCommand
        case loadingSurfaceNotFound
    }

    /// One mutation path for the loading pane of a Cloud workspace, shared by the
    /// socket's `workspace.cloud_vm_terminal_ready` (the CLI's `vm new`/`vm open`)
    /// and the in-process New Machine create. A deferred attachment keeps the loading
    /// card until the machine's real terminal is projected over it; only the full TUI
    /// client replaces the card with a local process running `command`.
    func replaceCloudVMLoadingPane(
        workspaceID: UUID,
        in tabManager: TabManager,
        command: String,
        deferTerminal: Bool,
        focus: Bool
    ) throws -> CloudVMTerminalAttachment {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            throw CloudVMTerminalAttachmentError.workspaceNotFound
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudVMTerminalAttachmentError.emptyCommand }
        guard let panelID = workspace.prepareCloudTerminalAttachment(
            command: trimmed, deferTerminal: deferTerminal, focus: focus
        ) else {
            throw CloudVMTerminalAttachmentError.loadingSurfaceNotFound
        }
        return CloudVMTerminalAttachment(workspace: workspace, panelID: panelID)
    }
}
