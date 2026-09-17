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

    static func aggregate(
        statusKeyedStates: [String: AgentHibernationLifecycleState],
        fallback: AgentHibernationLifecycleState?
    ) -> AgentHibernationLifecycleState {
        let states = statusKeyedStates
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value)
        guard !states.isEmpty else {
            return fallback ?? .unknown
        }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.idle) { return .idle }
        return fallback ?? .unknown
    }

    /// Restricts TextBox Escape authorization to the fixed built-in agent set.
    /// Custom Vault and manual lifecycle keys remain valid for hibernation state,
    /// but must not authorize a control key to an arbitrary process.
    static func aggregateForTextBoxEscape(
        statusKeyedStates: [String: AgentHibernationLifecycleState]
    ) -> AgentHibernationLifecycleState {
        var hasNeedsInput = false
        var hasUnknown = false
        var hasIdle = false

        // Iterate the fixed allowlist instead of filtering the unbounded runtime
        // map. This keeps the Escape authorization lookup bounded by built-ins.
        for key in AgentHibernationLifecycleStatusKeys.allowedStatusKeys {
            guard let state = statusKeyedStates[key] else { continue }
            switch state {
            case .running:
                return .running
            case .needsInput:
                hasNeedsInput = true
            case .unknown:
                hasUnknown = true
            case .idle:
                hasIdle = true
            }
        }

        if hasNeedsInput { return .needsInput }
        if hasUnknown { return .unknown }
        if hasIdle { return .idle }
        return .unknown
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
        "campfire",
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
