import CMUXMobileCore

/// Probe-specific failures discovered before or during the exact-address dial.
enum CmxIrohPrivatePathProbeDialError: Error, Equatable, Sendable {
    /// The broker has no fresh direct port for the requested address family.
    case stalePort

    /// The responding QUIC peer did not authenticate as the expected EndpointID.
    case wrongPeer
}
