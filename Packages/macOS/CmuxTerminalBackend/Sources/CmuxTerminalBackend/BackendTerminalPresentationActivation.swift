/// Proof that one connection-owned presentation is eligible to own terminal
/// input and geometry authority without configuring a renderer worker.
public struct BackendTerminalPresentationActivation: Decodable, Equatable, Sendable {
    /// The presentation whose terminal authority was activated.
    public let presentationID: PresentationID

    /// The exact presentation generation accepted by the daemon.
    public let presentationGeneration: UInt64

    /// The canonical PTY surface selected by the presentation.
    public let surfaceID: SurfaceID

    enum CodingKeys: String, CodingKey {
        case presentationID = "presentation_id"
        case presentationGeneration = "presentation_generation"
        case surfaceID = "surface_uuid"
    }
}
