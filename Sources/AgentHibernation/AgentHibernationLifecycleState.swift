import Foundation

enum AgentHibernationLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown
    case running
    case waiting
    case idle
    case needsInput
    case completed
    case failed

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self.parse(rawValue) ?? .unknown
    }

    /// Whether a hibernated agent panel can stay suspended in this state.
    var allowsHibernation: Bool {
        switch self {
        case .idle, .completed, .failed:
            return true
        case .unknown, .running, .waiting, .needsInput:
            return false
        }
    }

    /// Whether the agent is actively executing work (tools, model, compaction).
    var isActivelyRunning: Bool {
        self == .running
    }

    /// Whether the agent is blocked on user input, approval, or an error.
    var needsUserAttention: Bool {
        switch self {
        case .waiting, .needsInput, .failed:
            return true
        case .unknown, .running, .idle, .completed:
            return false
        }
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
        case "waiting":
            return .waiting
        case "idle":
            return .idle
        case "needsinput", "needs-input":
            return .needsInput
        case "completed", "complete", "done":
            return .completed
        case "failed", "error":
            return .failed
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
}
