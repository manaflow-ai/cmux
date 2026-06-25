public import Foundation

/// A `command` block declared in `cmux.json`: a named entry that either creates
/// a workspace (``workspace``) or runs a shell command (``command``), with
/// optional discovery keywords, a description, restart behavior, and a confirm
/// flag.
///
/// This is the `Codable`, `Sendable` wire image consumed by `CmuxConfigExecutor`
/// and the surface tab-bar command resolution. Its `init(from:)` enforces the
/// `cmux.json` schema invariants (non-blank name, non-blank command, and that a
/// command defines exactly one of `workspace`/`command`).
public struct CmuxCommandDefinition: Codable, Sendable, Identifiable {
    /// The command's display name.
    public var name: String
    /// An optional human-readable description.
    public var description: String?
    /// Optional discovery keywords used when searching for the command.
    public var keywords: [String]?
    /// How the command behaves when its target workspace already exists.
    public var restart: CmuxRestartBehavior?
    /// The workspace this command creates, mutually exclusive with ``command``.
    public var workspace: CmuxWorkspaceDefinition?
    /// The shell command this command runs, mutually exclusive with ``workspace``.
    public var command: String?
    /// Whether the command prompts for confirmation before running.
    public var confirm: Bool?

    /// A stable identifier derived from the command name.
    public var id: String {
        "cmux.config.command." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    /// Creates a command definition.
    public init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: CmuxRestartBehavior? = nil,
        workspace: CmuxWorkspaceDefinition? = nil,
        command: String? = nil,
        confirm: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.workspace = workspace
        self.command = command
        self.confirm = confirm
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        restart = try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart)
        workspace = try container.decodeIfPresent(CmuxWorkspaceDefinition.self, forKey: .workspace)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command name must not be blank"
                )
            )
        }
        if let cmd = command,
           cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define a blank 'command'"
                )
            )
        }

        if workspace != nil && command != nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define both 'workspace' and 'command'"
                )
            )
        }
        if workspace == nil && command == nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must define either 'workspace' or 'command'"
                )
            )
        }
    }
}
