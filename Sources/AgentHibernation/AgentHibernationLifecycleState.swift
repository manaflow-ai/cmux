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

    /// Merges an incoming lifecycle into an existing one without ever letting an
    /// indeterminate `unknown` erase a previously-proven definitive state.
    ///
    /// A process restart (SessionStart on session-restore or focus-resume)
    /// carries no turn-state information, so it reports `unknown`. That `unknown`
    /// must not clobber an earlier `idle`/`running`/`needsInput` that the agent
    /// actually emitted, otherwise a resumed-but-quiescent agent gets stuck at
    /// `unknown` and never becomes hibernation-eligible again (the
    /// hibernation-is-one-shot bug). This helper only *preserves* a proven state;
    /// it never *invents* idleness, so eligibility stays positive-evidence-only.
    ///
    /// - Parameters:
    ///   - existing: The currently-persisted lifecycle, if any.
    ///   - incoming: The lifecycle reported by the event being applied.
    /// - Returns: `incoming` unless it is `unknown` and `existing` is a definitive
    ///   (non-`nil`, non-`unknown`) state, in which case `existing` is kept. Any
    ///   definitive incoming state (`idle`/`running`/`needsInput`) always wins.
    static func preservingDefinitive(
        existing: AgentHibernationLifecycleState?,
        incoming: AgentHibernationLifecycleState
    ) -> AgentHibernationLifecycleState {
        guard incoming == .unknown, let existing, existing != .unknown else {
            return incoming
        }
        return existing
    }

    /// Resolves a panel's hibernation lifecycle from all of its per-agent status
    /// sources plus a persisted fallback.
    ///
    /// Priority: busy (`running`) or blocked (`needsInput`) first, then
    /// indeterminate (`unknown`), then definitive idle. `unknown` outranks `idle`
    /// so that any unclassified source blocks hibernation — a stale `.idle` from
    /// one agent key cannot mask an active `.unknown` from another key on the same
    /// panel. In practice each panel has one agent key at a time (the other is
    /// pruned via `clearAgentLifecycle`/`clearAgentLifecycleStates` at session end),
    /// so the single entry is whatever that agent last reported.
    static func resolved(
        from states: some Collection<AgentHibernationLifecycleState>,
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        guard !states.isEmpty else { return fallback ?? .unknown }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    /// The effective lifecycle for an agent session record: prefer a definitively
    /// emitted lifecycle, but when none was emitted (`nil`/`unknown`) treat a
    /// recorded idle completion notification as `idle`. This lets plugin/no-emit
    /// agents (e.g. opencode) become hibernation-eligible like codex when they
    /// finish, instead of being stuck at `unknown`.
    ///
    /// Safety note: both the explicit `agentLifecycle == .idle` path and the
    /// `lastNotificationStatus == "idle"` fallback can return stale data after an
    /// app restart — the persisted idle was from a previous completed turn, but the
    /// agent may have started a new turn before the restart. Callers MUST guard the
    /// returned `.idle` value with a durable `hasUnconfirmedTerminalInput` check
    /// that merges the persisted terminal-input timestamp against
    /// `lifecycleUpdatedAt` (the hook store field that advances only on definitive
    /// `.idle`/`.running`/`.needsInput` events, never on `.unknown` SessionStart):
    /// `max(durableTerminalInputAt, inMemoryInputAt) >
    /// max(lifecycleUpdatedAt, inMemoryLifecycleChangeAt)`. Using `updatedAt`
    /// instead of `lifecycleUpdatedAt` is incorrect: `updatedAt` advances on every
    /// upsert including `.unknown` SessionStart, which can push the baseline past
    /// a terminal-input timestamp and silently clear the mid-turn guard.
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
