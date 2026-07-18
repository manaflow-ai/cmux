/// One presentation owned by the current backend connection.
public struct BackendPresentation: Codable, Equatable, Sendable {
    /// The stable identifier used by presentation update and close requests.
    public let id: PresentationID

    /// The optimistic-concurrency generation expected by the next update.
    public let generation: UInt64

    /// The daemon-assigned numeric identifier of the owning connection.
    public let client: UInt64

    /// The canonical entities selected by this presentation.
    public let view: BackendPresentationView

    /// The pane zoom applied only to this presentation.
    public let zoom: BackendPresentationZoom

    /// The viewport binding applied only to this presentation.
    public let scroll: BackendPresentationScroll

    enum CodingKeys: String, CodingKey {
        case id = "presentation_id"
        case generation, client, view, zoom, scroll
    }
}
