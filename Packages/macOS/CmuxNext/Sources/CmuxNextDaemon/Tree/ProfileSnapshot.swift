import Foundation

/// One room (`profiles-v1`, plans/cmux-next/data-model.md; the wire calls
/// rooms profiles): a switchable set of workspaces and workspace groups with
/// its own theme, default browser profile and terminal defaults. Rooms tag
/// workspaces; they are not a tree level.
///
/// Wire shape (`list-workspaces.profiles[]`, `list-profiles`): `{id, name,
/// color, icon, theme, index, browser_profile_id, defaults: {cwd, env} | null}`.
public struct ProfileSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: ProfileID
    public var name: String
    /// Palette token (the 9 group color names) or `#RRGGBB[AA]`.
    public var color: String?
    /// SF Symbol name or one emoji.
    public var icon: String?
    /// Ghostty theme spec (`theme` syntax) coloring windows showing the room.
    public var theme: String?
    public var index: Int
    /// Default browser profile of the room's workspaces; nil = `default`.
    public var browserProfileID: BrowserProfileKey?
    public var defaults: ProfileDefaults?
    /// Session new workspaces are created on; nil = the home session.
    public var defaultSessionID: String?
    /// Sessions whose unpinned workspaces this room shows.
    public var follows: [String]

    public init(id: ProfileID, name: String, color: String? = nil, icon: String? = nil, theme: String? = nil, index: Int = 0,
                browserProfileID: BrowserProfileKey? = nil, defaults: ProfileDefaults? = nil, defaultSessionID: String? = nil,
                follows: [String] = []) {
        self.defaultSessionID = defaultSessionID
        self.follows = follows
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.theme = theme
        self.index = index
        self.browserProfileID = browserProfileID
        self.defaults = defaults
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, icon, theme, index, defaults, follows
        case browserProfileID = "browser_profile_id"
        case defaultSessionID = "default_session_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ProfileID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        browserProfileID = try c.decodeIfPresent(BrowserProfileKey.self, forKey: .browserProfileID)
        defaults = try c.decodeIfPresent(ProfileDefaults.self, forKey: .defaults)
        defaultSessionID = try c.decodeIfPresent(String.self, forKey: .defaultSessionID)
        follows = try c.decodeIfPresent([String].self, forKey: .follows) ?? []
    }
}

/// Terminal defaults of a profile. The daemon applies them to terminals
/// created in the profile's workspaces: `cwd` when the request has none,
/// `env` under the request's own environment.
public struct ProfileDefaults: Sendable, Hashable, Codable {
    public var cwd: String?
    public var env: [String: String]

    public init(cwd: String? = nil, env: [String: String] = [:]) {
        self.cwd = cwd
        self.env = env
    }

    public var isEmpty: Bool { (cwd?.isEmpty ?? true) && env.isEmpty }

    enum CodingKeys: String, CodingKey { case cwd, env }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        if !env.isEmpty { try c.encode(env, forKey: .env) }
    }
}
