import Foundation

extension AgentPaneView {
    /// Scrolls the transcript to turn `turnId` (a `#turn-<turnId>` link).
    /// A page that has not asked for its handshake yet (a tab the link just
    /// opened) gets the turn with it (``AgentPaneModel/pendingRevealTurn``);
    /// a loaded page gets it as the `revealTurn` event. Either way the page
    /// waits a few seconds for the row, then gives up quietly.
    ///
    /// - Parameter turnId: The acpmux turn id from the link.
    public func revealTurn(_ turnId: String) {
        guard model.hasHandshake else {
            model.pendingRevealTurn = turnId
            return
        }
        deliver([.revealTurn(turnId)])
    }
}
