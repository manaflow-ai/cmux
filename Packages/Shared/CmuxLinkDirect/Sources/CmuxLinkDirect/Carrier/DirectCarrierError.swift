/// Why a direct connect failed.
public enum DirectCarrierError: Error, Sendable, Hashable {
    /// The peer has no direct endpoint (no hints, nothing resolved).
    case noEndpoint
    /// No endpoint's route can work on the current path.
    case routeUnavailable(DirectRouteStatus.Blocker)
    /// The host closed during the handshake: it refused this device, or it
    /// is not the host this device pinned.
    case handshakeRefused
    /// Every endpoint failed; one message per attempt.
    case allEndpointsFailed([String])
}
