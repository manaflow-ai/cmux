/// One typed, ancestry-scoped projection-navigation mutation.
public enum BackendProjectionNavigationOperation: Codable, Equatable, Sendable {
    /// Adds a canonical workspace to a logical window's assignment set.
    case assignWorkspace(workspaceID: WorkspaceID)

    /// Removes a canonical workspace from a logical window's assignment set.
    case unassignWorkspace(workspaceID: WorkspaceID)

    /// Selects an assigned workspace, or clears the selection.
    case selectWorkspace(workspaceID: WorkspaceID?)

    /// Selects a screen within an assigned workspace.
    case selectScreen(workspaceID: WorkspaceID, screenID: ScreenID)

    /// Activates a layout-leaf pane within a screen.
    case activatePane(workspaceID: WorkspaceID, screenID: ScreenID, paneID: PaneID)

    /// Sets or clears the pane expanded over a screen.
    case setZoomedPane(workspaceID: WorkspaceID, screenID: ScreenID, paneID: PaneID?)

    /// Selects a terminal or native surface within a pane.
    case selectSurface(
        workspaceID: WorkspaceID,
        screenID: ScreenID,
        paneID: PaneID,
        surfaceID: SurfaceID
    )

    /// Decodes the operation's kebab-case discriminator and typed UUID fields.
    ///
    /// - Parameter decoder: The decoder containing one operation object.
    /// - Throws: A decoding error for an unknown tag or missing field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .type) {
        case .assignWorkspace:
            self = .assignWorkspace(
                workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID)
            )
        case .unassignWorkspace:
            self = .unassignWorkspace(
                workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID)
            )
        case .selectWorkspace:
            self = .selectWorkspace(
                workspaceID: try container.decodeIfPresent(WorkspaceID.self, forKey: .workspaceID)
            )
        case .selectScreen:
            self = .selectScreen(
                workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID),
                screenID: try container.decode(ScreenID.self, forKey: .screenID)
            )
        case .activatePane:
            self = .activatePane(
                workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID),
                screenID: try container.decode(ScreenID.self, forKey: .screenID),
                paneID: try container.decode(PaneID.self, forKey: .paneID)
            )
        case .setZoomedPane:
            self = .setZoomedPane(
                workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID),
                screenID: try container.decode(ScreenID.self, forKey: .screenID),
                paneID: try container.decodeIfPresent(PaneID.self, forKey: .paneID)
            )
        case .selectSurface:
            self = .selectSurface(
                workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID),
                screenID: try container.decode(ScreenID.self, forKey: .screenID),
                paneID: try container.decode(PaneID.self, forKey: .paneID),
                surfaceID: try container.decode(SurfaceID.self, forKey: .surfaceID)
            )
        }
    }

    /// Encodes the operation's kebab-case discriminator and typed UUID fields.
    ///
    /// - Parameter encoder: The encoder receiving one operation object.
    /// - Throws: Any error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .assignWorkspace(let workspaceID):
            try container.encode(Tag.assignWorkspace, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
        case .unassignWorkspace(let workspaceID):
            try container.encode(Tag.unassignWorkspace, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
        case .selectWorkspace(let workspaceID):
            try container.encode(Tag.selectWorkspace, forKey: .type)
            if let workspaceID {
                try container.encode(workspaceID, forKey: .workspaceID)
            } else {
                try container.encodeNil(forKey: .workspaceID)
            }
        case .selectScreen(let workspaceID, let screenID):
            try container.encode(Tag.selectScreen, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(screenID, forKey: .screenID)
        case .activatePane(let workspaceID, let screenID, let paneID):
            try container.encode(Tag.activatePane, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(screenID, forKey: .screenID)
            try container.encode(paneID, forKey: .paneID)
        case .setZoomedPane(let workspaceID, let screenID, let paneID):
            try container.encode(Tag.setZoomedPane, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(screenID, forKey: .screenID)
            if let paneID {
                try container.encode(paneID, forKey: .paneID)
            } else {
                try container.encodeNil(forKey: .paneID)
            }
        case .selectSurface(let workspaceID, let screenID, let paneID, let surfaceID):
            try container.encode(Tag.selectSurface, forKey: .type)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(screenID, forKey: .screenID)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(surfaceID, forKey: .surfaceID)
        }
    }

    private enum Tag: String, Codable {
        case assignWorkspace = "assign-workspace"
        case unassignWorkspace = "unassign-workspace"
        case selectWorkspace = "select-workspace"
        case selectScreen = "select-screen"
        case activatePane = "activate-pane"
        case setZoomedPane = "set-zoomed-pane"
        case selectSurface = "select-surface"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case workspaceID = "workspace_uuid"
        case screenID = "screen_uuid"
        case paneID = "pane_uuid"
        case surfaceID = "surface_uuid"
    }
}
