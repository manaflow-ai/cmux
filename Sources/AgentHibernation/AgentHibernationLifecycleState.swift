import Foundation

enum AgentHibernationLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown
    case running
    case idle
    case needsInput
    /// The agent hit an error or ran out of quota (sidebar ERROR/LIMIT).
    case error

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self.parse(rawValue) ?? .unknown
    }

    var allowsHibernation: Bool {
        self == .idle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parseCLIValue(_ rawValue: String) -> AgentHibernationLifecycleState? {
        parse(rawValue)
    }

    private static func parse(_ rawValue: String) -> AgentHibernationLifecycleState? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "unknown":
            return .unknown
        case "running":
            return .running
        case "idle":
            return .idle
        case "needsinput", "needs-input":
            return .needsInput
        case "error", "limited", "quota":
            return .error
        default:
            return nil
        }
    }
}

enum AgentHibernationLifecycleStatusKeys {
    /// Reserved namespace for `cmux workspace loading`: `manual` or
    /// `manual:<id>`. Excluded from `allowedStatusKeys` and from `isAllowed`
    /// (so `set_agent_lifecycle` rejects it): manual loaders enter only through
    /// the validated, capped `workspace_loading` path and drive the sidebar
    /// spinner, never hibernation/PID/status handling.
    static let manualKey = "manual"

    static func isManualKey(_ key: String) -> Bool {
        key == manualKey || key.hasPrefix("\(manualKey):")
    }

    static let allowedStatusKeys: Set<String> = [
        "amp",
        "antigravity",
        "claude_code",
        "codebuddy",
        "codex",
        "copilot",
        "cursor",
        "factory",
        "gemini",
        "grok",
        "hermes-agent",
        "kiro",
        "kimi",
        "omp",
        "opencode",
        "pi",
        "qoder",
        "rovodev",
    ]

    static func isAllowed(_ key: String) -> Bool {
        allowedStatusKeys.contains(key)
    }

    /// Prefix the Feed uses when it publishes attention under a second key
    /// beside the agent's own lifecycle key.
    static let feedAttentionPrefix = "cmux.feed.attention:"

    /// The agent a lifecycle key speaks for, or `nil` for reserved manual keys.
    ///
    /// Feed attention keys (`cmux.feed.attention:<agent>`) belong to that agent
    /// so a permission prompt can outrank the same agent's `running` without
    /// being treated as a second occupant of the pane.
    static func owningAgent(for key: String) -> String? {
        if isManualKey(key) { return nil }
        if key.hasPrefix(feedAttentionPrefix) {
            let agent = String(key.dropFirst(feedAttentionPrefix.count))
            return agent.isEmpty ? nil : agent
        }
        return key
    }

    /// Records `lifecycle` under `key` and drops every other agent's keys, so a
    /// leftover error from a previous occupant cannot paint over the one that
    /// is actually in the pane. Manual keys and the same agent's Feed attention
    /// key are kept.
    static func applying(
        key: String,
        lifecycle: AgentHibernationLifecycleState,
        to states: [String: AgentHibernationLifecycleState]
    ) -> [String: AgentHibernationLifecycleState] {
        var next = states
        if let owner = owningAgent(for: key) {
            next = next.filter { existing, _ in
                owningAgent(for: existing).map { $0 == owner } ?? true
            }
        }
        next[key] = lifecycle
        return next
    }
}
