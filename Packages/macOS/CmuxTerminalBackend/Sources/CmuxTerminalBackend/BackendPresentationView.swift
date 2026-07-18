/// Connection-owned canonical selection for one frontend view.
public struct BackendPresentationView: Codable, Equatable, Sendable {
    /// The selected workspace, or `nil` when no workspace is selected.
    public let workspaceID: WorkspaceID?

    /// The selected screen, or `nil` when no screen is selected.
    public let screenID: ScreenID?

    /// The selected pane, or `nil` when no pane is selected.
    public let paneID: PaneID?

    /// The selected surface, or `nil` when no surface is selected.
    public let surfaceID: SurfaceID?

    /// Creates a presentation selection.
    ///
    /// - Parameters:
    ///   - workspaceID: The selected workspace, or `nil`.
    ///   - screenID: The selected screen, or `nil`.
    ///   - paneID: The selected pane, or `nil`.
    ///   - surfaceID: The selected surface, or `nil`.
    public init(
        workspaceID: WorkspaceID? = nil,
        screenID: ScreenID? = nil,
        paneID: PaneID? = nil,
        surfaceID: SurfaceID? = nil
    ) {
        self.workspaceID = workspaceID
        self.screenID = screenID
        self.paneID = paneID
        self.surfaceID = surfaceID
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_uuid"
        case screenID = "screen_uuid"
        case paneID = "pane_uuid"
        case surfaceID = "surface_uuid"
    }

    var jsonValue: BackendJSONValue {
        .object([
            "workspace_uuid": workspaceID.map { .string($0.description) } ?? .null,
            "screen_uuid": screenID.map { .string($0.description) } ?? .null,
            "pane_uuid": paneID.map { .string($0.description) } ?? .null,
            "surface_uuid": surfaceID.map { .string($0.description) } ?? .null,
        ])
    }
}
