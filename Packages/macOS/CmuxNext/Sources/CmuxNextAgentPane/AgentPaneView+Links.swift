import Foundation

extension AgentPaneView {
    /// Scrolls the transcript to turn `turnId` (a `#turn-<turnId>` link),
    /// through the page's `cmuxAcpmuxBridge.revealTurn`. The page does
    /// nothing when no row carries that turn. The id reaches the page as a
    /// JSON string, never as script text.
    ///
    /// - Parameter turnId: The acpmux turn id from the link.
    public func revealTurn(_ turnId: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: turnId, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.cmuxAcpmuxBridge?.revealTurn?.(\(json));")
    }
}
