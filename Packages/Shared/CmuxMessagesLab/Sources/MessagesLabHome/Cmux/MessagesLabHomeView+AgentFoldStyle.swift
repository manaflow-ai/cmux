#if DEBUG
import Foundation

/// DEBUG ONLY: the Agent Messages Playground's switch (user 2026-11-02, msg 19613).
extension MessagesLabHomeView {
    /// Draws every agent-message fold, notes and note row in `style` from now on (one row provider for
    /// the process: every open Home view takes it when it next maps its rows) and redraws this view's
    /// rows at once. ``HomeAgentFoldStyle/current`` puts the shipped look back.
    public func debugSetAgentFoldStyle(_ style: HomeAgentFoldStyle) {
        CustomRows.register(HomeAgentFoldRowProvider(style: style.rawValue))
        projection.debugRebuild()
    }
}
#endif
