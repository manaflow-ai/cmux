/// One canonical surface attached to a backend pane.
public struct CanonicalSurface: Codable, Equatable, Sendable {
    /// The daemon-local numeric surface identifier.
    public let id: UInt64

    /// The stable surface identifier used across daemon restarts.
    public let uuid: SurfaceID

    /// The backend-defined surface kind.
    public let kind: String

    /// The optional canonical surface name.
    public let name: String?

    /// Creates a canonical surface.
    ///
    /// - Parameters:
    ///   - id: The daemon-local numeric surface identifier.
    ///   - uuid: The stable surface identifier.
    ///   - kind: The backend-defined surface kind.
    ///   - name: The optional canonical surface name.
    public init(id: UInt64, uuid: SurfaceID, kind: String, name: String?) {
        self.id = id
        self.uuid = uuid
        self.kind = kind
        self.name = name
    }
}
