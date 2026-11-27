import Foundation

// Screen metadata and order (`screen-metadata-v1`, cmux-tui/spec/commands.md
// `set-screen-metadata`, `set-screen-pinned`, `move-screen`, `new-screen`).
// Each change emits `screen-changed` with the full screen and its index.

// MoveScreenRequest is generated (bindings.json, family Screens); its response stays here.
extension MoveScreenRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var screen: ScreenID
        public var workspace: WorkspaceHandle
        /// The destination workspace's durable key.
        public var key: WorkspaceKey?
        public var index: Int
    }
}
