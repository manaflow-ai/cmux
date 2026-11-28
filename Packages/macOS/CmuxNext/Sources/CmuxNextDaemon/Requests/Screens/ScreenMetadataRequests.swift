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

// SetScreenMetadataRequest and SetScreenPinnedRequest are generated (bindings.json, family Screens);
// SetScreenPinnedRequest's response stays here.
extension SetScreenPinnedRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var screen: ScreenID
        public var pinned: Bool
        public var index: Int
        public var changed: Bool
    }
}
