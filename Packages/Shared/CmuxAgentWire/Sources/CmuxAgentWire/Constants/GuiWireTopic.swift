public import CmuxAgentReplica

/// Topic constants and builders for `gui.v1` server events.
// lint:allow namespace-type - The wire contract requires one topic namespace.
public enum GuiWireTopic {
    /// The foreground session-directory event topic.
    public static let sessions = "gui.v1.sessions"

    /// Builds the journal topic for one session.
    /// - Parameter sessionID: The session whose journal events are requested.
    /// - Returns: The session-scoped journal topic string.
    public static func journal(sessionID: AgentSessionID) -> String {
        "gui.v1.journal.\(sessionID.rawValue)"
    }
}
