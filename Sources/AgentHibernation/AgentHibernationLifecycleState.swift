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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parseCLIValue(_ rawValue: String) -> AgentHibernationLifecycleState? {
        parse(rawValue)
    }

    /// Resolve an `incoming` lifecycle against the currently stored one so an
    /// indeterminate `.unknown` never erases a previously proven definitive state.
    ///
    /// An agent reports `.unknown` when it has no turn-state information: a
    /// SessionStart right after a process restart, or a plugin agent that emits no
    /// live lifecycle. That `.unknown` must not overwrite an earlier `.idle` /
    /// `.running` / `.needsInput`, otherwise a restarted agent's status decays to
    /// `.unknown` and it never becomes hibernation-eligible again (only codex,
    /// which keeps reporting, would ever hibernate). A definitive incoming state
    /// always wins, so this never *invents* idleness: eligibility stays
    /// positive-evidence-only.
    ///
    /// - Returns: `incoming`, unless it is `.unknown` and `existing` is a definitive
    ///   (non-`nil`, non-`.unknown`) state, in which case `existing` is kept.
    static func preservingDefinitive(
        existing: AgentHibernationLifecycleState?,
        incoming: AgentHibernationLifecycleState
    ) -> AgentHibernationLifecycleState {
        guard incoming == .unknown, let existing, existing != .unknown else {
            return incoming
        }
        return existing
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
