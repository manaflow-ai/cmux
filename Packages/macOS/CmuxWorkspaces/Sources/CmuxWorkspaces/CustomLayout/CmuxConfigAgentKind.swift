import Foundation

/// A coding agent that a `cmux.json` action can launch.
///
/// ``commandName`` is the executable name run for the agent and ``defaultIcon``
/// is the SF Symbol shown when an action does not override its icon. The
/// hand-rolled ``Codable`` conformance encodes the canonical token (`codex` /
/// `claude`) and decodes a trimmed string accepting historical aliases
/// (`claudeCode`, `claude-code`), throwing `DecodingError.dataCorrupted` on an
/// unknown agent.
public enum CmuxConfigAgentKind: Sendable, Hashable {
    /// The Codex agent.
    case codex
    /// The Claude Code agent.
    case claudeCode

    /// The executable name launched for this agent.
    public var commandName: String {
        switch self {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        }
    }

    /// The SF Symbol shown when an action does not override its icon.
    public var defaultIcon: CmuxButtonIcon {
        switch self {
        case .codex:
            return .symbol("sparkles")
        case .claudeCode:
            return .symbol("brain.head.profile")
        }
    }
}

extension CmuxConfigAgentKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "codex":
            self = .codex
        case "claude", "claudeCode", "claude-code":
            self = .claudeCode
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown agent '\(value)'"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .codex:
            try container.encode("codex")
        case .claudeCode:
            try container.encode("claude")
        }
    }
}
