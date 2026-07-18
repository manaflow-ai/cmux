/// One canonical screen containing a pane layout and its panes.
public struct CanonicalScreen: Codable, Equatable, Sendable {
    /// The daemon-local numeric screen identifier.
    public let id: UInt64

    /// The stable screen identifier used across daemon restarts.
    public let uuid: ScreenID

    /// The optional canonical screen name.
    public let name: String?

    /// The split tree that references every pane exactly once.
    public let layout: CanonicalLayout

    /// The canonical panes contained by this screen.
    public let panes: [CanonicalPane]

    /// Creates a canonical screen.
    ///
    /// - Parameters:
    ///   - id: The daemon-local numeric screen identifier.
    ///   - uuid: The stable screen identifier.
    ///   - name: The optional canonical screen name.
    ///   - layout: The split tree for the screen's panes.
    ///   - panes: The canonical panes contained by the screen.
    public init(
        id: UInt64,
        uuid: ScreenID,
        name: String?,
        layout: CanonicalLayout,
        panes: [CanonicalPane]
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.layout = layout
        self.panes = panes
    }
}
