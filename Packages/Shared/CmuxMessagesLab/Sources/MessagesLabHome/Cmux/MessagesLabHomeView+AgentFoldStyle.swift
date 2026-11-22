#if DEBUG
import Foundation

/// DEBUG ONLY: the Agent Messages Playground's switch (user 2026-11-02, msg 19613).
extension MessagesLabHomeView {
    /// Draws every agent-message fold, notes and note row in `style` from now on (one row provider for
    /// the process: every open Home view takes it when it next maps its rows) and redraws this view's
    /// rows at once. ``HomeAgentFoldStyle/current`` puts the shipped look back. In a pill style a click on an
    /// agent's pill calls `onPill` with the agent's id and the message id of its row.
    public func debugSetAgentFoldStyle(_ style: HomeAgentFoldStyle, onPill: (@MainActor @Sendable (String, String) -> Void)? = nil) {
        let pill = onPill.map { onPill in { @MainActor @Sendable (peer: String, ref: PartRef) in onPill(peer, ref.messageId) } }
        CustomRows.register(HomeAgentFoldRowProvider(style: style.rawValue, onPill: pill))
        projection.debugRebuild()
    }
}
#endif
