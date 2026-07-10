public import CMUXMobileCore
public import Foundation

/// Errors raised while establishing or operating a ``CmxIrohByteTransport``.
public enum CmxIrohByteTransportError: Error, Equatable, Sendable {
    /// The iroh peer endpoint id was empty.
    case emptyPeerID
    /// The configured maximum receive length was not positive.
    case invalidMaximumReceiveLength(Int)
    /// The route kind cannot be served by the iroh transport.
    case unsupportedRouteKind(CmxAttachTransportKind)
    /// The endpoint is not a peer endpoint this transport can dial.
    case unsupportedEndpoint(CmxAttachEndpoint)
    /// An operation was attempted before the connection became ready.
    case notConnected
    /// The transport was already closed.
    case alreadyClosed
    /// The endpoint could not be bound.
    case endpointBindFailed(String, CmxConnectFailureKind)
    /// The peer connection failed.
    case connectionFailed(String, CmxConnectFailureKind)
    /// A receive failed; the associated value describes the cause.
    case receiveFailed(String)
    /// A send failed; the associated value describes the cause.
    case sendFailed(String)

    static func bindFailed(_ failure: CmxIrohFailure) -> CmxIrohByteTransportError {
        .endpointBindFailed(failure.message, failure.kind.connectFailureKind)
    }

    static func connectFailed(_ failure: CmxIrohFailure) -> CmxIrohByteTransportError {
        .connectionFailed(failure.message, failure.kind.connectFailureKind)
    }

    static func receiveFailed(_ failure: CmxIrohFailure) -> CmxIrohByteTransportError {
        .receiveFailed(failure.message)
    }

    static func sendFailed(_ failure: CmxIrohFailure) -> CmxIrohByteTransportError {
        .sendFailed(failure.message)
    }
}
