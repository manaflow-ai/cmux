import Foundation

/// The workspace-layout variant of a ``CmuxCommandDefinition`` entry.
struct CmuxWorkspaceLayoutCommandDefinition: Codable, Hashable, Sendable {
    let name: String
    var description: String?
    var keywords: [String]?
    var restart: CmuxRestartBehavior?
    var workspace: CmuxWorkspaceDefinition
    var confirm: Bool?

    var cwd: String? { workspace.cwd }
    var color: String? { workspace.color }
    var env: [String: String]? { workspace.env }
    var setup: String? { workspace.setup }
    var layout: CmuxLayoutNode? { workspace.layout }

    init?(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: CmuxRestartBehavior? = nil,
        workspace: CmuxWorkspaceDefinition,
        confirm: Bool? = nil
    ) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.workspace = workspace
        self.confirm = confirm
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, keywords, restart, workspace, confirm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: String(
                        localized: "config.validation.commandNameBlank",
                        defaultValue: "Command name must not be blank"
                    )
                )
            )
        }

        let workspace: CmuxWorkspaceDefinition
        if container.contains(.workspace), !((try? container.decodeNil(forKey: .workspace)) ?? false) {
            workspace = try container.decode(CmuxWorkspaceDefinition.self, forKey: .workspace)
        } else {
            // Older cmux.json files flatten the workspace fields directly into
            // the commands[] entry: {name, cwd, color, env, setup, layout}.
            workspace = try CmuxWorkspaceDefinition(
                from: decoder,
                layoutMode: .legacyFlattenedRoot
            )
        }

        guard let definition = Self(
            name: name,
            description: try container.decodeIfPresent(String.self, forKey: .description),
            keywords: try container.decodeIfPresent([String].self, forKey: .keywords),
            restart: try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart),
            workspace: workspace,
            confirm: try container.decodeIfPresent(Bool.self, forKey: .confirm)
        ) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: String(
                        localized: "config.validation.commandNameBlank",
                        defaultValue: "Command name must not be blank"
                    )
                )
            )
        }
        self = definition
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(keywords, forKey: .keywords)
        try container.encodeIfPresent(restart, forKey: .restart)
        try container.encode(workspace, forKey: .workspace)
        try container.encodeIfPresent(confirm, forKey: .confirm)
    }
}
