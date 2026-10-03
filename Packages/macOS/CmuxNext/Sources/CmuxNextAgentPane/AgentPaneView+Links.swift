import Foundation

extension AgentPaneView {
    /// Scrolls the transcript to turn `turnId` (a `#turn-<turnId>` link).
    /// A page that has not asked for its handshake yet (a tab the link just
    /// opened) gets the turn with it (``AgentPaneModel/pendingRevealTurn``);
    /// a loaded page gets it through `cmuxAcpmuxBridge.revealTurn`. Either
    /// way the page waits a few seconds for the row, then gives up quietly.
    /// The id reaches the page as a JSON string, never as script text.
    ///
    /// - Parameter turnId: The acpmux turn id from the link.
    public func revealTurn(_ turnId: String) {
        guard model.hasHandshake else {
            model.pendingRevealTurn = turnId
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: turnId, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.cmuxAcpmuxBridge?.revealTurn?.(\(json));")
    }
}
