public import CMUXMobileCore
import Foundation

/// Errors raised while establishing or operating a ``CmxWebSocketByteTransport``.
public enum CmxWebSocketByteTransportError: Error, Equatable, Sendable {
    /// The route kind cannot be served by this WebSocket transport.
    case unsupportedRouteKind(CmxAttachTransportKind)
    /// The endpoint is not a URL endpoint this transport can dial.
    case unsupportedEndpoint(CmxAttachEndpoint)
    /// The URL string could not be parsed as an absolute URL.
    case invalidURL(String)
    /// The URL does not use the `ws` or `wss` scheme.
    case unsupportedURLScheme(String?)
    /// An operation was attempted before the WebSocket became ready.
    case notConnected
    /// The transport was already closed.
    case alreadyClosed
    /// A connect was requested while another connect is still in flight.
    case connectAlreadyInProgress
    /// A receive was requested while another receive is still in flight.
    case receiveAlreadyInProgress
    /// A send was requested while another send is still in flight.
    case sendAlreadyInProgress
    /// The connection failed; the associated value describes the cause.
    case connectionFailed(String)
    /// A receive failed; the associated value describes the cause.
    case receiveFailed(String)
    /// A text WebSocket message was received where binary bytes were required.
    case receivedTextMessage
    /// A send failed; the associated value describes the cause.
    case sendFailed(String)
}
