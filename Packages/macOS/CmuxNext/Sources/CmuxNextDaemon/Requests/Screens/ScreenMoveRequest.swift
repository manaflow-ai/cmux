import Foundation

// Screen metadata and order (`screen-metadata-v1`, cmux-tui/spec/commands.md
// `set-screen-metadata`, `set-screen-pinned`, `move-screen`, `new-screen`).
// Each change emits `screen-changed` with the full screen and its index.

/// Moves a screen to `index` in its workspace, into `workspace` at `index`,
/// or into a new workspace (the screen keeps its panes, tabs, and
/// terminals). The daemon clamps a move that would break pinned-first order
/// or split a group.
public struct MoveScreenRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var screen: ScreenID
        public var workspace: WorkspaceHandle
        /// The destination workspace's durable key.
        public var key: WorkspaceKey?
        public var index: Int
    }
    public static let command = "move-screen"
    public static let requiredCapability: String? = DaemonCapabilities.shared.screenMetadata
    public var screen: ScreenID
    public var index: Int?
    public var workspace: WorkspaceHandle?
    /// Moves the screen into a new workspace created in the same commit.
    public var newWorkspace: Bool?
    public init(screen: ScreenID, index: Int? = nil, workspace: WorkspaceHandle? = nil, newWorkspace: Bool? = nil) {
        self.screen = screen
        self.index = index
        self.workspace = workspace
        self.newWorkspace = newWorkspace
    }
    enum CodingKeys: String, CodingKey {
        case screen, index, workspace
        case newWorkspace = "new_workspace"
    }
}
