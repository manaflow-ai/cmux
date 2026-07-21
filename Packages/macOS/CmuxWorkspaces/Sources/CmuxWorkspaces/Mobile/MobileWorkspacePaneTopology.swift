/// The identifiers and selected tab for one pane in spatial tree order.
public struct MobileWorkspacePaneTopology: Equatable, Sendable {
    /// The stable pane identifier.
    public let id: String

    /// Surface identifiers in tab order.
    public let surfaceIDs: [String]

    /// The selected surface identifier, when any.
    public let selectedSurfaceID: String?

    /// Creates one pane-topology snapshot.
    ///
    /// - Parameters:
    ///   - id: The stable pane identifier.
    ///   - surfaceIDs: Surface identifiers in tab order.
    ///   - selectedSurfaceID: The selected surface identifier, when any.
    public init(id: String, surfaceIDs: [String], selectedSurfaceID: String?) {
        self.id = id
        self.surfaceIDs = surfaceIDs
        self.selectedSurfaceID = selectedSurfaceID
    }
}
