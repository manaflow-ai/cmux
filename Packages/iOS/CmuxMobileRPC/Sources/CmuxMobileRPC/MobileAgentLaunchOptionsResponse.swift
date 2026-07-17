public import Foundation

/// Typed decoder for the `mobile.agent.launch_options` RPC result: what the
/// launch composer needs before offering a launch — the coding agents this Mac
/// can run and the working directories that make sense for a new agent
/// workspace.
public struct MobileAgentLaunchOptionsResponse: Decodable, Sendable {
    /// A coding agent the Mac knows how to launch with a prompt.
    public struct Agent: Decodable, Sendable {
        /// Stable agent identifier (`claude`, `codex`).
        public let id: String
        /// User-facing agent name reported by the Mac.
        public let name: String
        /// Whether the agent's executable resolves on the Mac right now.
        public let installed: Bool

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
            installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case installed
        }
    }

    /// A suggested working directory for the new workspace.
    public struct Directory: Decodable, Sendable {
        /// Absolute path on the Mac.
        public let path: String
    }

    /// Launchable agents in the Mac's preferred order.
    public let agents: [Agent]
    /// Suggested working directories, most relevant first.
    public let directories: [Directory]
    /// The directory a plain workspace create would inherit, if any.
    public let defaultDirectory: String?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decodeIfPresent([Agent].self, forKey: .agents) ?? []
        directories = try container.decodeIfPresent([Directory].self, forKey: .directories) ?? []
        defaultDirectory = try container.decodeIfPresent(String.self, forKey: .defaultDirectory)
    }

    private enum CodingKeys: String, CodingKey {
        case agents
        case directories
        case defaultDirectory = "default_directory"
    }

    public static func decode(_ data: Data) throws -> MobileAgentLaunchOptionsResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
