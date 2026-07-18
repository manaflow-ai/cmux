import Foundation

/// Selection contract for a remote tmux split. Every mutation caller must state
/// whether tmux may select the created pane; background automation uses
/// `preserveActivePane`, which maps to `split-window -d`.
enum RemoteTmuxSplitFocusIntent: Sendable, Equatable {
    case preserveActivePane
    case focusCreatedPane

    func command(vertical: Bool, windowID: Int, paneID: Int) -> String {
        let detached = self == .preserveActivePane ? " -d" : ""
        return "split-window\(detached) \(vertical ? "-v" : "-h") -t @\(windowID).%\(paneID)"
    }
}

/// Mutation boundary shared by session-owned pane projections and deliberately
/// standalone window-mirror fixtures.
@MainActor
protocol RemoteTmuxControlPaneMutationOwner: AnyObject {
    func controlFocus(pane tmuxPaneID: Int) -> Bool
    func sendInput(toPane tmuxPaneID: Int, text: String) -> Bool
    func sendKey(
        toPane tmuxPaneID: Int,
        name: String
    ) -> RemoteTmuxControlKeySendResult
    func requestSplit(
        fromPane tmuxPaneID: Int,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent
    ) -> Bool
    func requestResizePane(_ tmuxPaneID: Int, direction: String, amountCells: Int) -> Bool
    func requestResizePane(_ tmuxPaneID: Int, absoluteAxis: String, targetCells: Int) -> Bool
    func requestResizePane(
        _ tmuxPaneID: Int,
        absoluteAxis: String,
        targetPercentage: Int
    ) -> Bool
    func requestRespawnPane(
        _ tmuxPaneID: Int,
        command: String,
        workingDirectory: String?
    ) -> Bool
    func requestKillPane(_ tmuxPaneID: Int) -> Bool
}
