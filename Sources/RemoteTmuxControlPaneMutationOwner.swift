import Foundation

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
