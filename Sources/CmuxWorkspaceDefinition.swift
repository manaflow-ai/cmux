import Foundation

struct CmuxWorkspaceDefinition: Codable, Sendable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: CmuxLayoutNode?

    init(name: String? = nil, cwd: String? = nil, color: String? = nil, layout: CmuxLayoutNode? = nil) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            let defaults = decoder.userInfo[.cmuxWorkspaceColorDefaults] as? UserDefaults ?? .standard
            guard let normalized = WorkspaceTabColorSettings.resolvedColorHex(rawColor, defaults: defaults) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .color,
                    in: container,
                    debugDescription: "Invalid color \"\(rawColor)\". Expected 6-digit hex format (#RRGGBB) or a workspace color name"
                )
            }
            color = normalized
        } else {
            color = nil
        }
    }
}
