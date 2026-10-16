import Foundation

/// Agent-event context attached to notifications that originate from an agent
/// completion signal (CLI agent hooks, PTY prompt-turn detection). Purely
/// informational input for the user's notification-policy hooks — hooks can
/// filter on it (e.g. silence subagent completions) but cannot patch it.
/// Absent entirely for non-agent notifications (OSC 9/99/777, legacy senders).
struct TerminalNotificationPolicyAgentContext: Codable, Sendable, Equatable {
    /// Stable lowercase agent slug (`claude`, `codex`, `grok`, …).
    var kind: String?
    /// `AgentNotifyCategory` raw value (`turn-complete`, `needs-permission`,
    /// `idle-reminder`).
    var category: String?
    /// Whether background work was still running when the turn ended.
    var pending: Bool?
    /// Whether the event came from a nested subagent session.
    var isSubagent: Bool?
    /// Session binding revalidated after asynchronous policy evaluation.
    var sessionId: String?

    init(
        kind: String? = nil,
        category: String? = nil,
        pending: Bool? = nil,
        isSubagent: Bool? = nil,
        sessionId: String? = nil
    ) {
        self.kind = kind
        self.category = category
        self.pending = pending
        self.isSubagent = isSubagent
        self.sessionId = sessionId
    }
}
