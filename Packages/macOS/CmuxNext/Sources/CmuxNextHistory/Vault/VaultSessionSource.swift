package import CmuxNextHistory

/// Where the session vault reads past agent sessions from. The app reads each
/// machine's session journal (``AgentHistorySource``); tests pass fixed sessions.
@MainActor
package protocol VaultSessionSource: AnyObject {
    /// Reads what is new since the last call (no polling between calls).
    func refresh() async
    /// Every known session, newest activity first.
    func sessions() -> [AgentSession]
    /// Whether the session's agent still runs in a tab this app can show.
    func isLive(_ session: AgentSession) -> Bool
}
