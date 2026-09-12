import Foundation

/// The shell-command variant of a ``CmuxCommandDefinition`` entry.
struct CmuxShellCommandDefinition: Codable, Hashable, Sendable {
    let name: String
    var description: String?
    var keywords: [String]?
    var restart: CmuxRestartBehavior?
    let command: String
    var confirm: Bool?

    init?(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: CmuxRestartBehavior? = nil,
        command: String,
        confirm: Bool? = nil
    ) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.command = command
        self.confirm = confirm
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, keywords, restart, command, confirm
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

        guard let command = try container.decodeIfPresent(String.self, forKey: .command),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: String(
                        format: String(
                            localized: "config.validation.commandBlank",
                            defaultValue: "Command '%@' must not define a blank 'command'"
                        ),
                        name
                    )
                )
            )
        }

        guard let definition = Self(
            name: name,
            description: try container.decodeIfPresent(String.self, forKey: .description),
            keywords: try container.decodeIfPresent([String].self, forKey: .keywords),
            restart: try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart),
            command: command,
            confirm: try container.decodeIfPresent(Bool.self, forKey: .confirm)
        ) else {
            // The guards above establish this invariant; retain a typed
            // decoding failure if that implementation ever changes.
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: String(
                        format: String(
                            localized: "config.validation.commandBlank",
                            defaultValue: "Command '%@' must not define a blank 'command'"
                        ),
                        name
                    )
                )
            )
        }
        self = definition
    }
}
