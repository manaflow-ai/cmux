/// A leaf pane containing ordered workspace surfaces.
public struct MobilePaneNode: Sendable, Equatable {
    /// The stable pane identifier.
    public let id: String
    /// The selected surface identifier within the pane, when one is selected.
    public let selectedSurfaceID: String?
    /// The pane's surfaces in tab order.
    public let surfaces: [MobilePaneSurface]

    /// Creates a pane node.
    /// - Parameters:
    ///   - id: The stable pane identifier.
    ///   - selectedSurfaceID: The selected surface identifier, when known.
    ///   - surfaces: The pane's surfaces in tab order.
    public init(id: String, selectedSurfaceID: String?, surfaces: [MobilePaneSurface]) {
        self.id = id
        self.selectedSurfaceID = selectedSurfaceID
        self.surfaces = surfaces
    }
}
