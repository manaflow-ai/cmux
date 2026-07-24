/// One leaf pane in a synced workspace layout.
public struct MobileWorkspaceLayoutPane: Codable, Equatable, Sendable {
    /// The stable pane identifier.
    public let id: String

    /// The selected surface identifier, when the pane has a selection.
    public let selectedSurfaceID: String?

    /// The pane's surfaces in tab order.
    public let surfaces: [MobileWorkspaceLayoutSurface]

    /// Creates a pane snapshot.
    ///
    /// - Parameters:
    ///   - id: The stable pane identifier.
    ///   - selectedSurfaceID: The selected surface identifier, when any.
    ///   - surfaces: The pane's surfaces in tab order.
    public init(
        id: String,
        selectedSurfaceID: String?,
        surfaces: [MobileWorkspaceLayoutSurface]
    ) {
        self.id = id
        self.selectedSurfaceID = selectedSurfaceID
        self.surfaces = surfaces
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case selectedSurfaceID = "selected_surface_id"
        case surfaces
    }
}
