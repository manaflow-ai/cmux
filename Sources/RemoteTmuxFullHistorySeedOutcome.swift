import Foundation

/// How loading a mirrored pane's full tmux history ended.
enum RemoteTmuxFullHistorySeedOutcome: Equatable, Sendable {
    /// The surface was repainted with `historyRows` rows of history; `truncated`
    /// when tmux held more than one load reads.
    case loaded(historyRows: Int, truncated: Bool)
    /// The pane shows a full-screen app on the alternate screen, which has no history.
    case alternateScreen
    /// The query or capture failed, or the stream reset first.
    case failed
}
