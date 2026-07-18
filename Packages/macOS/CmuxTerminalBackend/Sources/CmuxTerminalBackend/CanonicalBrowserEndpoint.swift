/// The browser content endpoint exported for one canonical browser surface.
///
/// The enclosing topology snapshot supplies the daemon authority fence, while
/// ``CanonicalSurface`` supplies the daemon-local handle and stable surface ID.
/// A frontend must retain all three values with this descriptor before it can
/// claim that a browser presentation is attached to daemon-owned content.
public struct CanonicalBrowserEndpoint: Codable, Equatable, Sendable {
    /// The browser-frame transport understood by the frontend.
    public enum Transport: String, Codable, Equatable, Sendable {
        /// `attach-surface` browser state plus ordered base64 PNG frame events.
        case cmuxdPNGFrameStreamV1 = "cmuxd-png-frame-stream-v1"
    }

    /// How cmuxd obtained the browser runtime.
    public enum Source: String, Codable, Equatable, Sendable {
        case external
        case launched
    }

    /// Whether every frontend must materialize this browser endpoint.
    ///
    /// Browser frames remain daemon-owned in both cases. `frontendOptional`
    /// lets a frontend that does not implement the advertised transport omit
    /// the browser from its local presentation graph without rejecting the
    /// surrounding terminal topology. Omitting this field on the wire remains
    /// fail-closed and decodes as `required`.
    public enum FrontendProjection: String, Codable, Equatable, Sendable {
        case required
        case frontendOptional = "frontend-optional"
    }

    /// The exact content transport required to present this surface.
    public let transport: Transport

    /// Browser runtime provenance, when discovery has completed.
    public let source: Source?

    /// The browser endpoint's presentation requirement for this topology.
    public let frontendProjection: FrontendProjection

    /// Creates one canonical browser content descriptor.
    public init(
        transport: Transport,
        source: Source? = nil,
        frontendProjection: FrontendProjection = .required
    ) {
        self.transport = transport
        self.source = source
        self.frontendProjection = frontendProjection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decode(Transport.self, forKey: .transport)
        source = try container.decodeIfPresent(Source.self, forKey: .source)
        frontendProjection = try container.decodeIfPresent(
            FrontendProjection.self,
            forKey: .frontendProjection
        ) ?? .required
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transport, forKey: .transport)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(frontendProjection, forKey: .frontendProjection)
    }

    private enum CodingKeys: String, CodingKey {
        case transport
        case source
        case frontendProjection = "frontend_projection"
    }
}
