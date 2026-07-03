import Foundation

/// Decodes the backend Cloud VM attach-endpoint response into a
/// ``CmxCloudAttachEndpoint``, the cloud-route counterpart to
/// ``CmxPairingQRCode`` (issue #6700).
public struct CmxCloudAttach: Sendable {
    /// The transport label the backend uses for a cmuxd-remote WebSocket
    /// endpoint (`web/services/vms/drivers/types.ts`).
    public static let webSocketTransport = "websocket"

    /// Creates the codec. It is stateless: construct one inline at the call
    /// site.
    public init() {}

    /// Decode a `POST /api/vm/{id}/attach-endpoint` response body into a
    /// ``CmxCloudAttachEndpoint``.
    ///
    /// The transport is probed first so an SSH fallback (a differently-shaped
    /// endpoint the phone can't dial) surfaces as a typed
    /// ``CmxCloudAttachError/unsupportedTransport(_:)`` error rather than an
    /// opaque `DecodingError` from the WebSocket-shaped decode. One decoder is
    /// reused across both passes.
    ///
    /// - Parameter data: The raw JSON response body.
    /// - Throws: ``CmxCloudAttachError/unsupportedTransport(_:)`` for a
    ///   non-WebSocket endpoint, or a `DecodingError` for a malformed payload.
    public func decode(_ data: Data) throws -> CmxCloudAttachEndpoint {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(CmxCloudAttachTransportProbe.self, from: data)
        guard probe.transport == Self.webSocketTransport else {
            throw CmxCloudAttachError.unsupportedTransport(probe.transport)
        }
        return try decoder.decode(CmxCloudAttachEndpoint.self, from: data)
    }
}
