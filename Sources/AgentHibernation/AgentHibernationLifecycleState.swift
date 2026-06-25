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
    /// Reserved key namespace for manual/CLI-driven loading state (the
    /// `cmux loading` command). The bare key is `manual`; named loaders use
    /// `manual:<id>` so several can stack into the sidebar count. These keys are
    /// intentionally NOT part of `allowedStatusKeys`, so they only drive the
    /// sidebar activity spinner and never participate in structured agent-hook
    /// hibernation/PID/status handling, which keys off that set.
    static let manualKey = "manual"

    /// Whether `key` is the manual loading key or a `manual:<id>` named loader.
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
        "opencode",
        "pi",
        "qoder",
        "rovodev",
    ]

    static func isAllowed(_ key: String) -> Bool {
        isManualKey(key) || allowedStatusKeys.contains(key)
    }
}
