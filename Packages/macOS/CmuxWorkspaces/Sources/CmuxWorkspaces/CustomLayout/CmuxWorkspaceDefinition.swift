public import Foundation

extension CodingUserInfoKey {
    /// The `UserDefaults` a ``CmuxWorkspaceDefinition`` color decode consults for
    /// the workspace color palette. Absent in production decodes (which fall back
    /// to `.standard`); set by tests to isolate the palette lookup.
    public static let cmuxWorkspaceColorDefaults = CodingUserInfoKey(rawValue: "cmuxWorkspaceColorDefaults")!

    /// The color resolver a ``CmuxWorkspaceDefinition`` color decode uses to
    /// normalize a raw `color` string (a 6-digit hex or a palette color name)
    /// into a canonical `#RRGGBB` hex, or `nil` when the value is invalid.
    ///
    /// The resolver is injected by the decode site (the app supplies the
    /// AppKit-coupled `WorkspaceTabColorSettings.resolvedColorHex`) so this
    /// package value type never reaches up into the app target. The closure
    /// receives the raw string and the `UserDefaults` read from
    /// ``cmuxWorkspaceColorDefaults`` (defaulting to `.standard`). When no
    /// resolver is present, color normalization is skipped and the raw value is
    /// carried through unchanged.
    public static let cmuxWorkspaceColorResolver = CodingUserInfoKey(rawValue: "cmuxWorkspaceColorResolver")!
}

/// A `workspace` block declared in `cmux.json`: the per-workspace name, working
/// directory, tab color, inherited environment, and optional custom `layout`.
///
/// This is the `Codable`, `Sendable` wire image consumed by `CmuxConfigExecutor`
/// when a config command creates a workspace. Color decoding is delegated to an
/// injected resolver carried in ``CodingUserInfoKey/cmuxWorkspaceColorResolver``
/// so the app's AppKit color palette logic stays app-side.
public struct CmuxWorkspaceDefinition: Codable, Sendable {
    /// The workspace name.
    public var name: String?
    /// The workspace working directory.
    public var cwd: String?
    /// The normalized tab color hex (`#RRGGBB`), or `nil`.
    public var color: String?
    /// User-defined environment variables inherited by every shell spawned in the
    /// workspace (issue #5995). Managed `CMUX_*` variables always win.
    public var env: [String: String]?
    /// The optional custom split/pane layout.
    public var layout: CmuxLayoutNode?

    private enum CodingKeys: String, CodingKey {
        case name
        case cwd
        case color
        case env
        case layout
    }

    /// Creates a workspace definition.
    public init(
        name: String? = nil,
        cwd: String? = nil,
        color: String? = nil,
        env: [String: String]? = nil,
        layout: CmuxLayoutNode? = nil
    ) {
        self.name = name
        self.cwd = cwd
        self.color = color
        self.env = env
        self.layout = layout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        layout = try container.decodeIfPresent(CmuxLayoutNode.self, forKey: .layout)

        if let rawColor = try container.decodeIfPresent(String.self, forKey: .color) {
            let defaults = decoder.userInfo[.cmuxWorkspaceColorDefaults] as? UserDefaults ?? .standard
            let resolver = decoder.userInfo[.cmuxWorkspaceColorResolver]
                as? @Sendable (String, UserDefaults) -> String?
            if let resolver {
                guard let normalized = resolver(rawColor, defaults) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .color,
                        in: container,
                        debugDescription: "Invalid color \"\(rawColor)\". Expected 6-digit hex format (#RRGGBB) or a workspace color name"
                    )
                }
                color = normalized
            } else {
                color = rawColor
            }
        } else {
            color = nil
        }
    }
}
