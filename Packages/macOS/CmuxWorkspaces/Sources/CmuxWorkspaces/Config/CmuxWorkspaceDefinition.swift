import Foundation

/// A `cmux.json` workspace definition: the optional name, working directory,
/// resolved tab color, inherited environment variables, and split layout for a
/// workspace a command opens.
///
/// Decode resolves a `color` string (literal hex or a workspace color name)
/// through ``WorkspaceTabColorSettings/resolvedColorHex(_:defaults:)`` against the
/// `UserDefaults` carried on `decoder.userInfo[.cmuxWorkspaceColorDefaults]`
/// (production decode falls back to `.standard`), preserving the on-disk wire
/// format exactly.
public struct CmuxWorkspaceDefinition: Codable, Sendable, Hashable {
    public var name: String?
    public var cwd: String?
    public var color: String?
    /// User-defined environment variables inherited by every shell spawned in the
    /// workspace (issue #5995). Managed `CMUX_*` variables always win.
    public var env: [String: String]?
    /// Bootstrap command sent to the workspace's first terminal before that
    /// terminal's own surface `command`. Other panes do not wait for it.
    public var setup: String?
    public var layout: CmuxLayoutNode?

    public init(
        name: String? = nil,
        cwd: String? = nil,
        color: String? = nil,
        env: [String: String]? = nil,
        setup: String? = nil,
        layout: CmuxLayoutNode? = nil
    ) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.env = env
        self.setup = setup
        self.layout = layout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        if let rawSetup = try container.decodeIfPresent(String.self, forKey: .setup) {
            let trimmed = rawSetup.trimmingCharacters(in: .whitespacesAndNewlines)
            setup = trimmed.isEmpty ? nil : trimmed
        } else {
            setup = nil
        }
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            let defaults = decoder.userInfo[.cmuxWorkspaceColorDefaults] as? UserDefaults ?? .standard
            guard let normalized = WorkspaceTabColorSettings().resolvedColorHex(rawColor, defaults: defaults) else {
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
