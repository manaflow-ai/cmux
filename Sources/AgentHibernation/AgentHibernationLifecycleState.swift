import Foundation

enum AgentHibernationLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown
    case running
    case idle
    case needsInput

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self.parse(rawValue) ?? .unknown
    }

    var allowsHibernation: Bool {
        self == .idle
    }

    /// Resolves a panel's hibernation lifecycle from all of its per-agent status
    /// sources plus a persisted fallback.
    ///
    /// Priority: a busy (`running`) or blocked (`needsInput`) source wins, then a
    /// definitive `idle`, and only then the indeterminate `unknown`. `idle`
    /// intentionally outranks `unknown` so a real idle is never masked by an
    /// agent that also reports an indeterminate status (which previously blocked
    /// hibernation for those agents entirely).
    static func resolved(
        from states: some Collection<AgentHibernationLifecycleState>,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        guard !states.isEmpty else { return fallback ?? .unknown }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.idle) { return .idle }
        if states.contains(.unknown) { return .unknown }
        return fallback ?? .unknown
    }

    /// The effective lifecycle for an agent session record: prefer a definitively
    /// emitted lifecycle, but when none was emitted (`nil`/`unknown`) treat a
    /// recorded idle completion notification as `idle`. This lets plugin/no-emit
    /// agents (e.g. opencode) become hibernation-eligible like codex when they
    /// finish, instead of being stuck at `unknown`.
    static func effective(
        agentLifecycle: AgentHibernationLifecycleState?,
        lastNotificationStatus: String?
    ) -> AgentHibernationLifecycleState? {
        if let agentLifecycle, agentLifecycle != .unknown {
            return agentLifecycle
        }
        if lastNotificationStatus?.lowercased() == "idle" {
            return .idle
        }
        return agentLifecycle
    }

    /// Whether an agent notification represents a genuinely blocked state (a
    /// permission/approval prompt the user must answer) versus a benign "turn
    /// finished, waiting for your next message" notification. Only the former
    /// should keep an agent out of hibernation, since killing and resuming a
    /// mid-tool prompt would drop the in-flight tool call. Keyword matching
    /// mirrors the generic notification classifier.
    static func notificationIndicatesBlocked(subtitle: String, body: String) -> Bool {
        let haystacks = [subtitle, body]
        for keyword in ["permission", "approve", "approval"] where
            haystacks.contains(where: { $0.localizedCaseInsensitiveContains(keyword) }) {
            return true
        }
        return false
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
        default:
            return nil
        }
    }
}

enum AgentHibernationLifecycleStatusKeys {
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
        "opencode",
        "pi",
        "qoder",
        "rovodev",
    ]

    static func isAllowed(_ key: String) -> Bool {
        allowedStatusKeys.contains(key)
    }
}
