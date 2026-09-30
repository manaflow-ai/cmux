import Foundation

// Screen metadata and order (`screen-metadata-v1`, cmux-tui/spec/commands.md
// `set-screen-metadata`, `set-screen-pinned`, `move-screen`). Each change
// emits `screen-changed` with the full screen and its index.

public struct ScreenMetadataResult: Decodable, Sendable, Equatable {
    public var screen: ScreenID
    public var color: String?
    public var icon: String?
    public var changed: Bool
}

/// Shared screen color and icon. A field sent as JSON null clears it; an
/// omitted field keeps its value.
public struct SetScreenMetadataRequest: DaemonRequest {
    public typealias Response = ScreenMetadataResult
    public static let command = "set-screen-metadata"
    public var screen: ScreenID
    /// Palette token `[a-z][a-z0-9-]{0,31}` or `#RRGGBB[AA]`; frontends offer the nine group colors.
    public var color: FieldUpdate<String>
    /// SF Symbol name or one emoji grapheme.
    public var icon: FieldUpdate<String>

    public init(screen: ScreenID, color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged) {
        self.screen = screen
        self.color = color
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey { case screen, color, icon }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screen, forKey: .screen)
        try c.encode(color, forKey: .color)
        try c.encode(icon, forKey: .icon)
    }
}

/// Pins or unpins a screen. Pinned screens sort first and cannot be grouped.
public struct SetScreenPinnedRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var screen: ScreenID
        public var pinned: Bool
        public var index: Int
        public var changed: Bool
    }
    public static let command = "set-screen-pinned"
    public var screen: ScreenID
    public var pinned: Bool
    public init(screen: ScreenID, pinned: Bool) {
        self.screen = screen
        self.pinned = pinned
    }
}

/// Moves a screen to `index` in its workspace, or into `workspace` at
/// `index` (the screen keeps its panes, tabs, and terminals). A move that
/// would break pinned-first order or split a group is clamped by the daemon.
public struct MoveScreenRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var screen: ScreenID
        public var workspace: WorkspaceHandle
        public var index: Int
    }
    public static let command = "move-screen"
    public var screen: ScreenID
    public var index: Int?
    public var workspace: WorkspaceHandle?
    public init(screen: ScreenID, index: Int? = nil, workspace: WorkspaceHandle? = nil) {
        self.screen = screen
        self.index = index
        self.workspace = workspace
    }
}
