/// The transient outcome of testing one exact private-network address.
public enum CmxIrohPrivatePathProbeResult: Equatable, Sendable {
    /// The expected Mac completed an authenticated QUIC handshake at this address.
    ///
    /// - Parameter latencyMilliseconds: End-to-end broker resolution and handshake latency.
    case reachable(latencyMilliseconds: Int)

    /// The address did not produce an authenticated connection to the expected Mac.
    ///
    /// - Parameter failure: A bounded, credential-free reason suitable for UI.
    case unreachable(CmxIrohPrivatePathProbeFailure)
}
