/// One surface tab in a synced workspace pane.
public struct MobileWorkspaceLayoutSurface: Codable, Equatable, Sendable {
    /// The stable surface identifier.
    public let id: String

    /// The raw panel type reported by the Mac.
    public let type: String

    /// The surface's display title.
    public let title: String

    /// Creates a surface tab snapshot.
    ///
    /// - Parameters:
    ///   - id: The stable surface identifier.
    ///   - type: The raw panel type reported by the Mac.
    ///   - title: The surface's display title.
    public init(id: String, type: String, title: String) {
        self.id = id
        self.type = type
        self.title = title
    }
}
