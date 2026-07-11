import Foundation

/// Resolves one projected tmux pane to its sole mutation owner. Production
/// session workspaces always use their session mirror; a standalone window
/// mirror can own mutations only when no session is bound to the workspace.
@MainActor
struct RemoteTmuxControlPaneLocation {
    let containerPanelID: UUID
    let owner: any RemoteTmuxControlPaneMutationOwner
    let windowMirror: RemoteTmuxWindowMirror?
    let pane: RemoteTmuxControlPane

    func controlFocus() -> Bool {
        owner.controlFocus(pane: pane.tmuxPaneID)
    }

    func sendInput(_ text: String) -> Bool {
        owner.sendInput(toPane: pane.tmuxPaneID, text: text)
    }

    func sendKey(_ name: String) -> RemoteTmuxControlKeySendResult {
        owner.sendKey(toPane: pane.tmuxPaneID, name: name)
    }

    func requestSplit(vertical: Bool) -> Bool {
        owner.requestSplit(fromPane: pane.tmuxPaneID, vertical: vertical)
    }

    func requestResizePane(_ tmuxPaneID: Int, direction: String, amountCells: Int) -> Bool {
        owner.requestResizePane(tmuxPaneID, direction: direction, amountCells: amountCells)
    }

    func requestResizePane(_ tmuxPaneID: Int, absoluteAxis: String, targetCells: Int) -> Bool {
        owner.requestResizePane(tmuxPaneID, absoluteAxis: absoluteAxis, targetCells: targetCells)
    }

    func requestResizePane(
        _ tmuxPaneID: Int,
        absoluteAxis: String,
        targetPercentage: Int
    ) -> Bool {
        owner.requestResizePane(
            tmuxPaneID,
            absoluteAxis: absoluteAxis,
            targetPercentage: targetPercentage
        )
    }

    func requestRespawn(command: String, workingDirectory: String?) -> Bool {
        owner.requestRespawnPane(
            pane.tmuxPaneID,
            command: command,
            workingDirectory: workingDirectory
        )
    }

    func requestKill() -> Bool {
        owner.requestKillPane(pane.tmuxPaneID)
    }
}
