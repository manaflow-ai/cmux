import Foundation

// Screen metadata and order (`screen-metadata-v1`, cmux-tui/spec/commands.md
// `set-screen-metadata`, `set-screen-pinned`, `move-screen`, `new-screen`).
// Each change emits `screen-changed` with the full screen and its index.

public struct ScreenMetadataResult: Decodable, Sendable, Equatable {
    public var screen: ScreenID
    public var color: String?
    public var icon: String?
    public var changed: Bool
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
    public static let requiredCapability: String? = DaemonCapability.screenMetadata.rawValue
    public var screen: ScreenID
    public var pinned: Bool
    public init(screen: ScreenID, pinned: Bool) {
        self.screen = screen
        self.pinned = pinned
    }
}
