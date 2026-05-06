import Foundation

struct CmuxSurfaceDefinition: Codable, Sendable {
    var type: CmuxSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var path: String?
    var focus: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case command
        case cwd
        case env
        case url
        case path
        case focus
    }

    init(
        type: CmuxSurfaceType,
        name: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        path: String? = nil,
        focus: Bool? = nil
    ) {
        if type == .markdown {
            precondition(
                path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "Markdown surface requires a non-empty path"
            )
        }

        self.type = type
        self.name = name
        self.command = command
        self.cwd = cwd
        self.env = env
        self.url = url
        self.path = path
        self.focus = focus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(CmuxSurfaceType.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        focus = try container.decodeIfPresent(Bool.self, forKey: .focus)

        guard type == .markdown else { return }
        guard let path else {
            throw DecodingError.keyNotFound(
                CodingKeys.path,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Markdown surface requires a 'path'"
                )
            )
        }
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.path],
                    debugDescription: "Markdown surface path must not be empty"
                )
            )
        }
    }
}

enum CmuxSurfaceType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
}
