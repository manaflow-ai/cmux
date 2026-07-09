import Foundation

/// Describes the agent implementation that owns a session.
public enum AgentKind: Codable, Hashable, Sendable {
    /// A Claude-backed agent.
    case claude
    /// A Codex-backed agent.
    case codex
    /// An unrecognized agent kind preserved for fail-open decoding.
    case unknown(String)

    /// The raw string carried on the wire and in replay logs.
    public var rawValue: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .unknown(let raw): raw
        }
    }

    /// Creates an agent kind from a raw string.
    /// - Parameter rawValue: The raw kind value.
    public init(rawValue: String) {
        switch rawValue {
        case "claude": self = .claude
        case "codex": self = .codex
        default: self = .unknown(rawValue)
        }
    }

    /// Decodes a fail-open agent kind.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    /// Encodes the raw agent kind string.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
