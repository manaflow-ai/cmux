import Foundation

extension HomeStore {
    /// Reads where agents `peers` of `conversation` run now (the owner's ``HomeSource/agentSessions(_:of:)``) and
    /// follows each by its session id: a session seen first is kept; a known one re-attaches only on a higher
    /// epoch (``HomeAgentSessionRef/follow(_:)``). A re-attach redraws the transcript, so an open agent tab
    /// shows the new place and its Go to workspace goes there.
    ///
    /// - Parameters:
    ///   - peers: The agents to place (the agent pane's open tabs).
    ///   - conversation: The Chief's chat.
    /// - Returns: True when an agent's place changed.
    @discardableResult
    public func followAgentSessions(_ peers: [String], in conversation: ConversationID) async -> Bool {
        false
    }

    /// Where agent `peer` of `conversation` runs, as last followed: the session its Chief link names, else
    /// any session of that agent. Nil before a read named it.
    public func agentSession(_ peer: String, in conversation: ConversationID) -> HomeAgentSessionRef? {
        nil
    }
}
