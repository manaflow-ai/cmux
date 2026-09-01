import Foundation

/// The shell-command variant of a ``CmuxCommandDefinition`` entry.
struct CmuxShellCommandDefinition: Codable, Hashable, Sendable {
    var name: String
    var description: String?
    var keywords: [String]?
    var restart: CmuxRestartBehavior?
    var command: String?
    var confirm: Bool?

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: CmuxRestartBehavior? = nil,
        command: String? = nil,
        confirm: Bool? = nil
    ) {
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
                    debugDescription: "Command name must not be blank"
                )
            )
        }

        guard let command = try container.decodeIfPresent(String.self, forKey: .command),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define a blank 'command'"
                )
            )
        }

        self.name = name
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        self.restart = try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart)
        self.command = command
        self.confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
    }
}
