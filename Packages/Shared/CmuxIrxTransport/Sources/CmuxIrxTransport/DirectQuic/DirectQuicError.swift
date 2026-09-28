/// Direct QUIC carrier failures.
public enum DirectQuicError: Error, Equatable, Sendable {
    /// The listener could not bind its port or load the TLS identity.
    case listenerUnavailable
    /// Network.framework refused a new stream on the connection group.
    case streamUnavailable
    /// The connection ended; the payload is the rendered close cause.
    case connectionClosed(String)
    /// The device-key handshake did not complete; the payload says why.
    case handshakeFailed(String)
    /// The server proved a device key other than the one the dialer expected.
    case peerIdentityMismatch
    /// The dial target had an empty host or a zero port.
    case invalidEndpoint
}
