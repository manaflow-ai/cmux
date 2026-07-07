import Foundation

/// Which coding agent runtime a session belongs to.
///
/// Raw values match the `_source` strings the agent hook integrations emit,
/// so hook events map directly. Unknown sources round-trip through
/// ``ChatAgentKind/other(_:)``.
public enum ChatAgentKind: Sendable, Equatable, Hashable {
    /// Claude Code.
    case claude
    /// OpenAI Codex CLI.
    case codex
    /// Any other agent runtime, identified by its raw `_source` string.
    case other(String)

    /// Creates a kind from a raw `_source` string.
    ///
    /// - Parameter source: The hook event source identifier.
    public init(source: String) {
        switch source {
        case "claude": self = .claude
        case "codex": self = .codex
        default: self = .other(source)
        }
    }

    /// The raw `_source` string this kind round-trips to.
    public var sourceName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .other(let source): return source
        }
    }

    /// Short human-readable display name (e.g. "Claude").
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .other(let source): return source.capitalized
        }
    }
}

extension ChatAgentKind: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(source: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sourceName)
    }
}
