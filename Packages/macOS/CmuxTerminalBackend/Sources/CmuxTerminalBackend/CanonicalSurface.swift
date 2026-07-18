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

    /// The daemon browser content endpoint. Non-browser surfaces omit it.
    public let browserEndpoint: CanonicalBrowserEndpoint?

    /// Durable, non-secret provenance for a parser-only external terminal.
    public let externalTerminalProvenance: CanonicalExternalTerminalProvenance?

    /// Creates a canonical surface.
    ///
    /// - Parameters:
    ///   - id: The daemon-local numeric surface identifier.
    ///   - uuid: The stable surface identifier.
    ///   - kind: The backend-defined surface kind.
    ///   - name: The optional canonical surface name.
    ///   - browserEndpoint: The daemon browser content endpoint, when this is a browser.
    ///   - externalTerminalProvenance: The external producer identity, when present.
    public init(
        id: UInt64,
        uuid: SurfaceID,
        kind: String,
        name: String?,
        browserEndpoint: CanonicalBrowserEndpoint? = nil,
        externalTerminalProvenance: CanonicalExternalTerminalProvenance? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.kind = kind
        self.name = name
        self.browserEndpoint = browserEndpoint
        self.externalTerminalProvenance = externalTerminalProvenance
    }

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case kind
        case name
        case browserEndpoint = "browser_endpoint"
        case externalTerminalProvenance = "external_terminal_provenance"
    }
}
