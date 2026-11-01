import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// Commands used by the native action catalog for header and "..." menu rows.
/// The page owns each operation's current session and availability; this view
/// only delivers the scoped command to the page already shown in this tab.
extension AgentPaneView {
    public func toggleDisplaySettings() { sendMenuCommand("toggleDisplaySettings") }
    public func replayConversation() { sendMenuCommand("replayConversation") }
    public func editProjectInstructions() { sendMenuCommand("editInstructions") }
    public func addProjectFiles() { sendMenuCommand("addProjectFiles") }
    public func moveToFloatingChat() { sendMenuCommand("floatingChat") }
    public func toggleThreadMinimap() { sendMenuCommand("toggleMinimap") }
    /// Continue After Error: the page runs the failed last turn's Continue or Retry, as its card does.
    public func continueAfterError() { sendMenuCommand("continueAfterError") }

    private func sendMenuCommand(_ command: String) {
        // Include the page's current session in the command. The App drops a command whose
        // session no longer matches this view after a tab switch, so a queued palette run cannot
        // toggle or open a panel in a replacement chat.
        let value = "menu:\(command)|\(model.sessionId ?? "")"
        let script = "window.cmuxAcpmuxBridge?.command?.(\(JSONValue.string(value).compactText));"
        deliver([.command(value)], scripts: [script])
    }
}
