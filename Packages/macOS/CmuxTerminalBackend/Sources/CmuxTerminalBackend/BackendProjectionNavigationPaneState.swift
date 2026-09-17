/// One pane's selected surface in a daemon-retained window projection.
public struct BackendProjectionNavigationPaneState: Codable, Equatable, Sendable {
    /// The canonical pane identifier.
    public let paneID: PaneID

    /// The canonical surface selected in the pane.
    public let selectedSurfaceID: SurfaceID

    /// Creates one pane preference.
    ///
    /// - Parameters:
    ///   - paneID: The canonical pane identifier.
    ///   - selectedSurfaceID: The canonical surface selected in the pane.
    public init(paneID: PaneID, selectedSurfaceID: SurfaceID) {
        self.paneID = paneID
        self.selectedSurfaceID = selectedSurfaceID
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_uuid"
        case selectedSurfaceID = "selected_surface_uuid"
    }
}
