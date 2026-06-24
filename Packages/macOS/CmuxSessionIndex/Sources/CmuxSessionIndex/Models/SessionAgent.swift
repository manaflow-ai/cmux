import CMUXAgentLaunch
import Foundation

/// The agent that produced a session: a built-in CLI agent or a vault-registered one.
///
/// Encodes as a bare string for built-ins (`"claude"`, `"codex"`, …) and as a keyed
/// `{id,name,iconAssetName}` object for registered agents, so both forms round-trip
/// through the same `Codable`.
public enum SessionAgent: Identifiable, Codable, Sendable, Hashable {
    case claude
    case codex
    case grok
    case opencode
    case rovodev
    case hermesAgent
    case registered(RegisteredSessionAgent)

    public var id: String { rawValue }

    public static let builtInCases: [SessionAgent] = [.claude, .codex, .grok, .opencode, .rovodev, .hermesAgent]

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "claude": self = .claude
        case "codex": self = .codex
        case "grok": self = .grok
        case "opencode": self = .opencode
        case "rovodev": self = .rovodev
        case "hermes-agent": self = .hermesAgent
        default:
            guard CmuxVaultAgentRegistration.isValidID(value) else { return nil }
            self = .registered(RegisteredSessionAgent(id: value))
        }
    }

    public var rawValue: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .grok: return "grok"
        case .opencode: return "opencode"
        case .rovodev: return "rovodev"
        case .hermesAgent: return "hermes-agent"
        case .registered(let agent): return agent.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconAssetName
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.id) {
            let id = try container.decode(String.self, forKey: .id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            let iconAssetName = try container.decodeIfPresent(String.self, forKey: .iconAssetName)
            let hasRegisteredMetadata = name != nil || iconAssetName != nil
            if let builtIn = SessionAgent(rawValue: id),
               (!CmuxVaultAgentRegistration.isValidID(id) || SessionAgent.builtInCases.contains(builtIn)),
               !hasRegisteredMetadata {
                self = builtIn
                return
            }
            guard CmuxVaultAgentRegistration.isValidID(id) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Invalid session agent '\(id)'"
                )
            }
            self = .registered(RegisteredSessionAgent(
                id: id,
                name: name,
                iconAssetName: iconAssetName
            ))
            return
        }

        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let agent = SessionAgent(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid session agent '\(value)'"
                )
            )
        }
        self = agent
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .registered(let agent):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(agent.id, forKey: .id)
            try container.encodeIfPresent(agent.name, forKey: .name)
            try container.encodeIfPresent(agent.iconAssetName, forKey: .iconAssetName)
        default:
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}
