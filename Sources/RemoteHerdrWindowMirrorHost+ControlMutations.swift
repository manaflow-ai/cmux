import CmuxNestedTopology
import Foundation

@MainActor
extension RemoteHerdrWindowMirrorHost {
    /// Forwards typed bytes to a Herdr pane (`pane.send` / `pane.send_keys`).
    ///
    /// Prefers the session-host serialized send channel so keystrokes stay ordered.
    @discardableResult
    func sendInput(toPane paneID: String, text: String) -> Bool {
        guard !text.isEmpty, panelsByPaneId[paneID] != nil else { return false }
        if let onSendInputRequest {
            onSendInputRequest(paneID, text)
            return true
        }
        return false
    }

    /// User chrome split → ``pane.split`` (never a local Bonsplit split).
    @discardableResult
    func requestSplit(fromPane paneID: String, vertical: Bool) -> Bool {
        guard panelsByPaneId[paneID] != nil else { return false }
        guard RemoteHerdrControl.requestSplit(
            fromPaneID: paneID,
            vertical: vertical
        ) != nil else { return false }
        onSplitPaneRequest?(paneID, vertical)
        return true
    }

    /// Absolute cell resize → ``pane.resize``.
    @discardableResult
    func requestResizePane(_ paneID: String, cols: Int, rows: Int) -> Bool {
        guard panelsByPaneId[paneID] != nil, cols >= 1, rows >= 1 else { return false }
        onResizePaneRequest?(paneID, cols, rows)
        return true
    }

    /// User pane close → ``pane.close`` (host tab close still detaches only).
    @discardableResult
    func requestKillPane(_ paneID: String) -> Bool {
        guard panelsByPaneId[paneID] != nil else { return false }
        let intent = RemoteHerdrControl.closeIntent(source: "user_pane", paneID: paneID)
        guard intent.action == "close_pane" || intent.action == "confirm_then_close_pane" else {
            return false
        }
        onClosePaneRequest?(paneID)
        return true
    }
}
