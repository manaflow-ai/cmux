/// Stable failure kinds reported by the remote-frame transport.
///
/// The embedding app owns user-facing localization.
public enum CmuxRemoteFrameTransportFailure: Sendable, Equatable {
    /// The supplied frame transport could not be opened or validated.
    case invalidTransport
    /// The producer marked an adopted frame transport as failed.
    case producerFailed
}
