import Foundation

// Screen metadata and order (`screen-metadata-v1`, cmux-tui/spec/commands.md
// `set-screen-metadata`, `set-screen-pinned`, `move-screen`, `new-screen`).
// Each change emits `screen-changed` with the full screen and its index.

/// What a new screen starts with (`screen-metadata-v1`): metadata applied
/// in the same commit that creates the screen, and its position.
public struct ScreenSpec: Sendable, Hashable {
    public var name: String?
    public var color: String?
    public var icon: String?
    public var pinned: Bool?
    /// Index in the workspace's screen list (default: the end).
    public var index: Int?
    /// Joins this screen group.
    public var group: ScreenGroupID?

    public init(name: String? = nil, color: String? = nil, icon: String? = nil, pinned: Bool? = nil, index: Int? = nil,
                group: ScreenGroupID? = nil) {
        self.name = name
        self.color = color
        self.icon = icon
        self.pinned = pinned
        self.index = index
        self.group = group
    }

    public var isEmpty: Bool { self == ScreenSpec() }
}

/// `new-screen` with metadata, position, and spawn options (daemons with
/// `screen-metadata-v1`; older daemons get the plain `NewScreenRequest`).
public struct NewScreenWithSpecRequest: TerminalSpawningRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var screen: ScreenID?
        public var terminalID: TerminalID?
        enum CodingKeys: String, CodingKey {
            case surface, screen
            case terminalID = "terminal_id"
        }
    }
    public static let command = "new-screen"
    public var workspace: WorkspaceHandle?
    public var spec: ScreenSpec
    public var options: SpawnOptions

    public init(workspace: WorkspaceHandle?, spec: ScreenSpec, options: SpawnOptions = SpawnOptions()) {
        self.workspace = workspace
        self.spec = spec
        self.options = options
    }

    enum CodingKeys: String, CodingKey { case workspace, color, icon, pinned, index, group, screenName = "screen_name" }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(workspace, forKey: .workspace)
        try c.encodeIfPresent(spec.name, forKey: .screenName)
        try c.encodeIfPresent(spec.color, forKey: .color)
        try c.encodeIfPresent(spec.icon, forKey: .icon)
        try c.encodeIfPresent(spec.pinned, forKey: .pinned)
        try c.encodeIfPresent(spec.index, forKey: .index)
        try c.encodeIfPresent(spec.group, forKey: .group)
        try options.encode(to: encoder)
    }
}
