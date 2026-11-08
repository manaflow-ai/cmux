import Foundation

/// Mutation boundary shared by session-owned pane projections and deliberately
/// standalone window-mirror fixtures.
@MainActor
protocol RemoteTmuxControlPaneMutationOwner: AnyObject {
    func controlFocus(
        pane tmuxPaneID: Int,
        completion: @escaping (Bool) -> Void
    ) -> Bool
    func sendInput(toPane tmuxPaneID: Int, text: String) -> Bool
    func sendKey(
        toPane tmuxPaneID: Int,
        name: String
    ) -> RemoteTmuxControlKeySendResult
    func requestSplit(
        fromPane tmuxPaneID: Int,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent,
        insertBefore: Bool,
        shellCommand: String?,
        workingDirectory: String?
    ) -> Bool
    func requestAgentForkNewWindow(
        afterPane tmuxPaneID: Int,
        shellCommand: String,
        workingDirectory: String?
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

@MainActor
extension RemoteTmuxControlPaneMutationOwner {
    func controlFocus(pane tmuxPaneID: Int) -> Bool {
        controlFocus(pane: tmuxPaneID, completion: { _ in })
    }

    func requestSplit(
        fromPane tmuxPaneID: Int,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent
    ) -> Bool {
        requestSplit(
            fromPane: tmuxPaneID,
            vertical: vertical,
            focusIntent: focusIntent,
            insertBefore: false,
            shellCommand: nil,
            workingDirectory: nil
        )
    }

    func requestAgentForkNewWindow(
        afterPane tmuxPaneID: Int,
        shellCommand: String,
        workingDirectory: String?
    ) -> Bool {
        false
    }
}
