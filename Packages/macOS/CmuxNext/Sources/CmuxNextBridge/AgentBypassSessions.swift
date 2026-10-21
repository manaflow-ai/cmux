import CmuxNextCompat

/// The agent chats this app opened in a mode that does not ask before acting (another machine's
/// running chat, `agent-session-adopt` answered `asking: false`), by session id, for observers:
/// each workspace row that shows one carries the bypass warning (``SidebarMapping``).
@MainActor
public final class AgentBypassSessions {
    public static let shared = AgentBypassSessions()
    private let sessions = ObservedMap<String, Bool>()

    public init() {}

    public func set(_ session: String, bypass: Bool) { sessions[session] = bypass ? true : nil }

    /// Observes `session` only.
    public func contains(_ session: String) -> Bool { sessions[session] == true }
}
