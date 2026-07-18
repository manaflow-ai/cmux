/// Stable identities and daemon-local handles for one canonical terminal surface.
public struct BackendSurfacePlacement: Decodable, Equatable, Sendable {
    /// Authority-fenced topology commit containing this placement.
    public let receipt: BackendTopologyMutationReceipt

    /// Daemon-local terminal-surface handle.
    public let surface: UInt64

    /// Stable terminal-surface identity.
    public let surfaceID: SurfaceID

    /// Daemon-local pane handle.
    public let pane: UInt64

    /// Stable pane identity.
    public let paneID: PaneID

    /// Daemon-local screen handle.
    public let screen: UInt64

    /// Stable screen identity.
    public let screenID: ScreenID

    /// Daemon-local workspace handle.
    public let workspace: UInt64

    /// Stable workspace identity.
    public let workspaceID: WorkspaceID

    private enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case baseRevision = "base_revision"
        case revision
        case replayed
        case surface
        case surfaceID = "surface_uuid"
        case pane
        case paneID = "pane_uuid"
        case screen
        case screenID = "screen_uuid"
        case workspace
        case workspaceID = "workspace_uuid"
    }

    /// Decodes a placement and its flat topology commit token.
    ///
    /// - Parameter decoder: Decoder containing placement and commit fields.
    /// - Throws: Any field decoding error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receipt = try BackendTopologyMutationReceipt(from: decoder)
        surface = try container.decode(UInt64.self, forKey: .surface)
        surfaceID = try container.decode(SurfaceID.self, forKey: .surfaceID)
        pane = try container.decode(UInt64.self, forKey: .pane)
        paneID = try container.decode(PaneID.self, forKey: .paneID)
        screen = try container.decode(UInt64.self, forKey: .screen)
        screenID = try container.decode(ScreenID.self, forKey: .screenID)
        workspace = try container.decode(UInt64.self, forKey: .workspace)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
    }
}
