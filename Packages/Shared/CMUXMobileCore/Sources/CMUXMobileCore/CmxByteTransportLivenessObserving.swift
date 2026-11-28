/// Optional nonblocking liveness snapshot for the native transport underneath
/// a byte lane. A lane request can time out while the shared QUIC session is
/// still healthy, so callers must not replace that session based on a single
/// stalled application stream.
public protocol CmxByteTransportLivenessObserving: CmxByteTransport {
    /// Returns `true` only after the complete underlying transport has closed.
    /// Before a transport is connected, implementations return `false`.
    func isTransportClosed() async -> Bool
}
