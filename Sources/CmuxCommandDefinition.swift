import Foundation

/// A reusable cmux command, represented as either a shell command or a workspace layout.
enum CmuxCommandDefinition: Codable, Hashable, Identifiable, Sendable {
    case command(CmuxShellCommandDefinition)
    case layout(CmuxWorkspaceLayoutCommandDefinition)

    private enum CodingKeys: String, CodingKey {
        case command
        case workspace
        case cwd
        case color
        case env
        case setup
        case layout
    }

    // Keep the source-compatible initializer used by existing callers. A
    // command wins when both forms are supplied, matching the historical
    // decoder's discriminator rule. The failable result prevents callers
    // from constructing an entry that has neither runnable form.
    init?(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: CmuxRestartBehavior? = nil,
        workspace: CmuxWorkspaceDefinition? = nil,
        command: String? = nil,
        confirm: Bool? = nil
    ) {
        if let command {
            guard let definition = CmuxShellCommandDefinition(
                    name: name,
                    description: description,
                    keywords: keywords,
                    restart: restart,
                    command: command,
                    confirm: confirm
                ) else {
                return nil
            }
            self = .command(definition)
        } else if let workspace {
            guard let definition = CmuxWorkspaceLayoutCommandDefinition(
                    name: name,
                    description: description,
                    keywords: keywords,
                    restart: restart,
                    workspace: workspace,
                    confirm: confirm
                ) else {
                return nil
            }
            self = .layout(definition)
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.command), !((try? container.decodeNil(forKey: .command)) ?? false) {
            // A command field is the discriminator. In particular, ignore
            // flattened layout metadata on mixed entries so an unrelated
            // layout cannot make an otherwise runnable command fail to load.
            self = .command(try CmuxShellCommandDefinition(from: decoder))
            return
        }

        let hasNestedWorkspace = container.contains(.workspace)
            && !((try? container.decodeNil(forKey: .workspace)) ?? false)
        let hasFlattenedWorkspace = [CodingKeys.cwd, .color, .env, .setup, .layout].contains { key in
            container.contains(key) && !((try? container.decodeNil(forKey: key)) ?? false)
        }
        guard hasNestedWorkspace || hasFlattenedWorkspace else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: String(
                        localized: "config.validation.missingDefinition",
                        defaultValue: "must define either 'command' or a workspace layout"
                    )
                )
            )
        }

        self = .layout(try CmuxWorkspaceLayoutCommandDefinition(from: decoder))
    }

    var name: String {
        switch self {
        case .command(let command):
            return command.name
        case .layout(let layout):
            return layout.name
        }
    }

    var description: String? {
        switch self {
        case .command(let command):
            return command.description
        case .layout(let layout):
            return layout.description
        }
    }

    var keywords: [String]? {
        switch self {
        case .command(let command):
            return command.keywords
        case .layout(let layout):
            return layout.keywords
        }
    }

    var restart: CmuxRestartBehavior? {
        switch self {
        case .command(let command):
            return command.restart
        case .layout(let layout):
            return layout.restart
        }
    }

    var workspace: CmuxWorkspaceDefinition? {
        switch self {
        case .command:
            return nil
        case .layout(let layout):
            return layout.workspace
        }
    }

    /// Convenience projections for legacy flattened workspace entries.
    var cwd: String? { workspace?.cwd }
    var color: String? { workspace?.color }
    var env: [String: String]? { workspace?.env }
    var setup: String? { workspace?.setup }
    var layout: CmuxLayoutNode? { workspace?.layout }

    var command: String? {
        switch self {
        case .command(let command):
            return command.command
        case .layout:
            return nil
        }
    }

    var confirm: Bool? {
        switch self {
        case .command(let command):
            return command.confirm
        case .layout(let layout):
            return layout.confirm
        }
    }

    var id: String {
        "cmux.config.command." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .command(let command):
            try command.encode(to: encoder)
        case .layout(let layout):
            try layout.encode(to: encoder)
        }
    }
}
