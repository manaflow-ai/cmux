public import Foundation

/// A provider understood by the conversation broker.
public enum ConversationProvider: Hashable, Sendable, Codable {
    /// OpenAI Codex through its app-server protocol.
    case codex
    /// Claude Code through its bidirectional streaming protocol.
    case claudeCode
    /// OpenCode through its HTTP/SSE server protocol.
    case openCode
    /// A provider generation that this client does not yet understand.
    case unknown(String)

    /// The stable wire spelling used by RPC and journal records.
    public var rawValue: String {
        switch self { case .codex: "codex"; case .claudeCode: "claude-code"; case .openCode: "opencode"; case .unknown(let value): value }
    }

    /// Creates a provider from its stable wire spelling.
    /// - Parameter rawValue: The provider spelling.
    public init(rawValue: String) {
        switch rawValue { case "codex": self = .codex; case "claude-code", "claude": self = .claudeCode; case "opencode", "open-code": self = .openCode; default: self = .unknown(rawValue) }
    }

    public init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// The lifecycle of a managed conversation session.
public enum ConversationSessionState: String, Codable, Hashable, Sendable {
    /// The provider connection is available for commands.
    case ready
    /// A provider process is starting or reconnecting.
    case starting
    /// The provider process has stopped and no command can execute.
    case stopped
    /// The session is archived from the task list.
    case archived
    /// The provider state cannot be restored without user action.
    case failed
}

/// A trusted provider launch destination.
public enum ConversationLaunchTarget: Codable, Hashable, Sendable {
    /// A provider process launched on this Mac in the supplied directory.
    case local(directory: String)
    /// A provider process launched over an approved SSH destination.
    case ssh(host: String, directory: String, arguments: [String])
    /// A cloud transport whose native connection is not configured locally.
    case cloud(endpoint: String)

    private enum CodingKeys: String, CodingKey { case kind, host, directory, command, endpoint }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "local": self = .local(directory: try c.decode(String.self, forKey: .directory))
        case "ssh": self = .ssh(host: try c.decode(String.self, forKey: .host), directory: try c.decode(String.self, forKey: .directory), arguments: try c.decodeIfPresent([String].self, forKey: .command) ?? [])
        case "cloud": self = .cloud(endpoint: try c.decode(String.self, forKey: .endpoint))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown conversation launch target")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let directory): try c.encode("local", forKey: .kind); try c.encode(directory, forKey: .directory)
        case .ssh(let host, let directory, let arguments): try c.encode("ssh", forKey: .kind); try c.encode(host, forKey: .host); try c.encode(directory, forKey: .directory); try c.encode(arguments, forKey: .command)
        case .cloud(let endpoint): try c.encode("cloud", forKey: .kind); try c.encode(endpoint, forKey: .endpoint)
        }
    }
}
