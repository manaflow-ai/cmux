public import CMUXMobileCore

/// Route and lifecycle failures raised by ``CmxIrohByteTransport``.
public enum CmxIrohByteTransportError: Error, Equatable, Sendable {
    /// A non-Iroh route was passed to the Iroh factory.
    case unsupportedRouteKind(CmxAttachTransportKind)

    /// The route does not carry a canonical Iroh peer identity.
    case unsupportedEndpoint(CmxAttachEndpoint)

    /// The caller omitted the expected Mac binding or admission authorization mode.
    case missingPeerIntent

    /// The transport was closed before the requested operation.
    case alreadyClosed

    /// Send or receive was attempted before successful admission.
    case notConnected

    /// Another RPC session already owns framing on this peer's control lane.
    case controlLaneAlreadyOwned
}
