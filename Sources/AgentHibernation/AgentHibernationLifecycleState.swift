import Foundation

public enum AgentHibernationLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown
    case running
    case idle
    case needsInput

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self.parse(rawValue) ?? .unknown
    }

    var allowsHibernation: Bool {
        self == .idle
    }

    public func encode(to encoder: Encoder) throws {
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
    /// Reserved namespace for `cmux workspace loading`: `manual` or
    /// `manual:<id>`. Excluded from `allowedStatusKeys` and from `isAllowed`
    /// (so `set_agent_lifecycle` rejects it): manual loaders enter only through
    /// the validated, capped `workspace_loading` path and drive the sidebar
    /// spinner, never hibernation/PID/status handling.
    static let manualKey = "manual"

    static func isManualKey(_ key: String) -> Bool {
        key == manualKey || key.hasPrefix("\(manualKey):")
    }

    private static let detectionPrefix = "screen:"

    static func detectionKey(familyID: String) -> String {
        detectionPrefix + familyID
    }

    static func isDetectionKey(_ key: String) -> Bool {
        key.hasPrefix(detectionPrefix)
    }

    static func detectionFamilyID(key: String) -> String? {
        guard isDetectionKey(key) else { return nil }
        return String(key.dropFirst(detectionPrefix.count))
    }

    static let allowedStatusKeys: Set<String> = [
        "amp",
        "antigravity",
        "campfire",
        "claude_code",
        "cline",
        "codebuddy",
        "codex",
        "copilot",
        "cursor",
        "devin",
        "factory",
        "gemini",
        "grok",
        "hermes-agent",
        "kilo",
        "kiro",
        "kimi",
        "maki",
        "mastracode",
        "ollama",
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

extension AgentHibernationLifecycleState {
    static func effective<S: Sequence>(_ states: S) -> AgentHibernationLifecycleState where S.Element == Self {
        let values = Array(states)
        if values.contains(.running) { return .running }
        if values.contains(.needsInput) { return .needsInput }
        if values.contains(.unknown) { return .unknown }
        if values.contains(.idle) { return .idle }
        return .unknown
    }
}
