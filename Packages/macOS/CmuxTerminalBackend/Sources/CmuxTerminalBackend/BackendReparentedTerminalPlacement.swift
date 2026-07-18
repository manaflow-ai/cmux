/// The stable and daemon-local identities returned after moving a canonical terminal.
public struct BackendReparentedTerminalPlacement: Decodable, Equatable, Sendable {
    /// Whether this request changed canonical topology. A retry after success returns `false`.
    public let moved: Bool

    /// Daemon-local workspace handle after the move.
    public let workspace: UInt64

    /// Stable workspace identity after the move.
    public let workspaceID: WorkspaceID

    /// Daemon-local screen handle after the move.
    public let screen: UInt64

    /// Stable screen identity after the move.
    public let screenID: ScreenID

    /// Daemon-local pane handle after the move.
    public let pane: UInt64

    /// Stable pane identity after the move.
    public let paneID: PaneID

    /// Unchanged daemon-local terminal-surface handle.
    public let surface: UInt64

    /// Unchanged stable terminal-surface identity.
    public let surfaceID: SurfaceID

    private enum CodingKeys: String, CodingKey {
        case moved
        case workspace
        case workspaceID = "workspace_uuid"
        case screen
        case screenID = "screen_uuid"
        case pane
        case paneID = "pane_uuid"
        case surface
        case surfaceID = "surface_uuid"
    }
}
