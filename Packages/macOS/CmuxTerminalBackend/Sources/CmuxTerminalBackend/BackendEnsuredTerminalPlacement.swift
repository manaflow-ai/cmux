/// The stable and daemon-local identities returned by an idempotent terminal attach.
public struct BackendEnsuredTerminalPlacement: Decodable, Equatable, Sendable {
    /// Whether this request created the PTY. `false` means it attached to the existing terminal.
    public let created: Bool

    /// Daemon-local workspace handle.
    public let workspace: UInt64

    /// Stable workspace identity supplied by the caller.
    public let workspaceID: WorkspaceID

    /// Daemon-local screen handle.
    public let screen: UInt64

    /// Stable screen identity allocated by the backend.
    public let screenID: ScreenID

    /// Daemon-local pane handle.
    public let pane: UInt64

    /// Stable pane identity allocated by the backend.
    public let paneID: PaneID

    /// Daemon-local terminal-surface handle.
    public let surface: UInt64

    /// Stable terminal-surface identity supplied by the caller.
    public let surfaceID: SurfaceID

    private enum CodingKeys: String, CodingKey {
        case created
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
