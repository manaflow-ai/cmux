import Foundation

struct CmuxWorkspaceDefinition: Codable, Sendable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: CmuxLayoutNode?
    var remote: CmuxRemoteDefinition?
    /// Program to run as the surface's child process for non-remote workspaces.
    /// Empty/nil falls back to Ghostty's default shell. Ignored when
    /// `remote` is set — the SSH invocation always wins.
    var program: String?

    init(
        name: String? = nil,
        cwd: String? = nil,
        color: String? = nil,
        layout: CmuxLayoutNode? = nil,
        remote: CmuxRemoteDefinition? = nil,
        program: String? = nil
    ) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.layout = layout
        self.remote = remote
        self.program = program
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)
        // `remote` and `program` are runtime-only — they're populated by the
        // `WorkspaceCommandsStore` projection when the executor runs a
        // workspace command. Workspace commands aren't authored in cmux.json
        // anymore, so the JSON decoder does not accept these keys.
        remote = nil
        program = nil

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
