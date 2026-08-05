/// A surface tab contained by a mobile pane node.
public struct MobilePaneSurface: Sendable, Equatable {
    /// The stable surface identifier shared with terminal RPC identifiers.
    public let id: String
    /// The surface's content type.
    public let type: MobilePaneSurfaceType
    /// The surface's display title as reported by the Mac.
    public let title: String

    /// Creates a pane surface snapshot.
    /// - Parameters:
    ///   - id: The stable surface identifier.
    ///   - type: The surface's content type.
    ///   - title: The surface's display title.
    public init(id: String, type: MobilePaneSurfaceType, title: String) {
        self.id = id
        self.type = type
        self.title = title
    }
}
