/// One fixed-size control frame in the acknowledged admission barrier.
public enum CmxIrohAdmissionFrame: Equatable, Sendable {
    /// The server accepted the credential, but NAT traversal remains gated.
    case acceptedPendingNatTraversal

    /// The server accepted the credential and intentionally keeps this
    /// connection relay-bound without authorizing NAT traversal.
    case acceptedRelayOnly

    /// The server denied admission with a non-sensitive protocol code.
    case denied(code: UInt16)

    /// The client authorized NAT traversal on its exact connection.
    case clientReady

    /// The server authorized NAT traversal and is ready for application lanes.
    case serverReady
}
