/// Minimal transport-only view used before full Cloud VM endpoint decoding.
///
/// Probing the transport first lets an SSH fallback surface as
/// ``CmxCloudAttachError/unsupportedTransport(_:)`` rather than an opaque
/// `DecodingError` from the WebSocket-shaped decode.
struct CmxCloudAttachTransportProbe: Decodable {
    let transport: String

    private enum CodingKeys: String, CodingKey {
        case transport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
            ?? CmxCloudAttach.webSocketTransport
    }
}
