import Foundation

extension Workspace {
    /// Identifies the agent session that opened one logical turn on a panel.
    ///
    /// Keeping the session token with the timestamp prevents a delayed stop
    /// hook from an older process from clearing a replacement turn.
    struct AgentTurnStartRecord: Equatable {
        let sessionID: String
        let startedAt: Date
    }
}
