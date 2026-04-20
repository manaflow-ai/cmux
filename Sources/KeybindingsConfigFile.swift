import Foundation

enum KeybindingsConfigFile {
    struct Schema: Codable {
        var version: Int?
        var custom_commands: [CustomCommandBinding]?
    }
}

struct CustomCommandBinding: Codable, Equatable, Identifiable {
    var id: String
    var shortcut: String
    var command: String
    var label: String?
    var target: CustomCommandTarget
    var cwd: CustomCommandWorkingDirectory?

    var resolvedWorkingDirectory: CustomCommandWorkingDirectory {
        cwd ?? .workspace
    }
}

enum CustomCommandTarget: String, Codable, Equatable {
    case splitRight = "split_right"
    case splitDown = "split_down"
    case newSurface = "new_surface"
    case newTab = "new_tab"
    case newWorkspace = "new_workspace"
}

enum CustomCommandWorkingDirectory: Codable, Equatable {
    case workspace
    case pane
    case absolutePath(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "workspace":
            self = .workspace
        case "pane":
            self = .pane
        default:
            guard rawValue.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "cwd must be \"workspace\", \"pane\", or an absolute path"
                )
            }
            self = .absolutePath(rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .workspace:
            try container.encode("workspace")
        case .pane:
            try container.encode("pane")
        case .absolutePath(let path):
            try container.encode(path)
        }
    }
}
