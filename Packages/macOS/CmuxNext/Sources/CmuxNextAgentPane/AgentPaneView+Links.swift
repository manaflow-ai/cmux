import Foundation

extension AgentPaneView {
    /// Scrolls the transcript to turn `turnId` (a `#turn-<turnId>` link),
    /// through the page's `cmuxAcpmuxBridge.revealTurn`. The page does
    /// nothing when no row carries that turn.
    ///
    /// - Parameter turnId: The acpmux turn id from the link.
    public func revealTurn(_ turnId: String) {
    }
}
