/// A redacted reason one exact private-network address could not reach its Mac.
public enum CmxIrohPrivatePathProbeFailure: Equatable, Sendable {
    /// The phone has no usable route to the supplied address.
    case noRoute

    /// The constrained attempt did not finish before its deadline.
    case timedOut

    /// The address was reachable, but no Iroh listener accepted the connection.
    case macNotListening

    /// The broker no longer has a fresh direct UDP port for this Mac and address family.
    case stalePort

    /// A QUIC peer answered without authenticating as the expected Mac EndpointID.
    case wrongPeer

    /// The signed route, active endpoint, or authenticated binding is unavailable.
    case unavailable

    /// Another private-path probe already owns the single probe slot.
    case busy
}
