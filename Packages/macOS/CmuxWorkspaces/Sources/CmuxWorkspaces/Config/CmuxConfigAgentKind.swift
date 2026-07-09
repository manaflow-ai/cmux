import Foundation

/// A coding-agent kind a `cmux.json` action can launch: Codex or Claude Code.
/// Decodes from the `agent` string (accepting the historical `claude`,
/// `claudeCode`, and `claude-code` spellings) and supplies the agent's launch
/// command and default tab-bar icon.
public enum CmuxConfigAgentKind: Sendable, Hashable {
    /// OpenAI Codex (`codex`).
    case codex
    /// Anthropic Claude Code (`claude`).
    case claudeCode

    /// The executable name used to launch the agent.
    public var commandName: String {
        switch self {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        }
    }

    /// The icon shown for the agent when an action does not declare its own.
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
