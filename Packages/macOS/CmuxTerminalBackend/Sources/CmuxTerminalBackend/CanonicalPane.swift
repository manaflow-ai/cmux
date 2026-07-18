/// One canonical pane containing one or more attached surfaces.
public struct CanonicalPane: Codable, Equatable, Sendable {
    /// The daemon-local numeric pane identifier.
    public let id: UInt64

    /// The stable pane identifier used across daemon restarts.
    public let uuid: PaneID

    /// The optional canonical pane name.
    public let name: String?

    /// The canonical surfaces in tab order.
    public let tabs: [CanonicalSurface]

    /// Creates a canonical pane.
    ///
    /// - Parameters:
    ///   - id: The daemon-local numeric pane identifier.
    ///   - uuid: The stable pane identifier.
    ///   - name: The optional canonical pane name.
    ///   - tabs: The canonical surfaces in tab order.
    public init(
        id: UInt64,
        uuid: PaneID,
        name: String?,
        tabs: [CanonicalSurface]
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.tabs = tabs
    }
}
