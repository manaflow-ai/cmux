public import CMUXMobileCore

/// Why an iroh dial failed, classified from the FFI's stable `CmuxIrohErrorKind`
/// so the UI can give an actionable message. The app layer maps this onto the
/// shared `CmxConnectFailureKind` when registering the transport.
public enum CmxIrohConnectFailureKind: Sendable, Equatable {
    /// The dial or an I/O op exceeded its deadline (commonly the Mac is asleep
    /// or unreachable on a bad network).
    case timedOut
    /// The QUIC handshake failed: the Mac is offline, or no path (relay or
    /// direct) could be established to the dialed EndpointId.
    case peerUnreachable
    /// Binding the local phone endpoint failed (bad key, no network).
    case bindFailed
    /// An established connection dropped mid-stream.
    case connectionLost
    /// Anything else (invalid argument, internal error).
    case generic

    /// Maps the FFI's `CmuxIrohErrorKind` value (ABI-stable integer, see
    /// cmux_iroh_ffi.h) onto a failure kind. Keyed on the documented numbers so
    /// it does not depend on how the C enum imports into Swift.
    init(rawKind: Int32) {
        switch rawKind {
        case 3: self = .timedOut // CMUX_IROH_ERROR_TIMEOUT
        case 4: self = .peerUnreachable // CMUX_IROH_ERROR_CONNECT_FAILED
        case 2: self = .bindFailed // CMUX_IROH_ERROR_BIND_FAILED
        case 5, 6: self = .connectionLost // ENDPOINT_CLOSED, CONNECTION_LOST
        default: self = .generic
        }
    }
}

/// Errors raised while establishing or operating a ``CmxIrohByteTransport``.
public enum CmxIrohByteTransportError: Error, Equatable, Sendable {
    /// The route kind cannot be served by this transport.
    case unsupportedRouteKind(CmxAttachTransportKind)
    /// The endpoint is not a `.peer` endpoint this transport can dial.
    case unsupportedEndpoint(CmxAttachEndpoint)
    /// The provided secret key was not exactly 32 bytes.
    case invalidSecretKey
    /// Generating a fresh secret key failed.
    case keyGenerationFailed
    /// An operation was attempted before ``connect()`` succeeded.
    case notConnected
    /// The transport was already closed.
    case alreadyClosed
    /// Binding the local endpoint failed; the value describes the cause.
    case bindFailed(String)
    /// The dial failed; the values describe the cause and a classified
    /// ``CmxIrohConnectFailureKind`` so the UI can give an actionable message.
    case connectFailed(String, CmxIrohConnectFailureKind)
    /// Accepting an incoming connection failed or timed out (host side).
    case acceptFailed(String, CmxIrohConnectFailureKind)
    /// An operation needed a bound endpoint but the listener was not started.
    case notStarted
    /// A receive failed; the value describes the cause.
    case receiveFailed(String)
    /// A send failed; the value describes the cause.
    case sendFailed(String)
}
