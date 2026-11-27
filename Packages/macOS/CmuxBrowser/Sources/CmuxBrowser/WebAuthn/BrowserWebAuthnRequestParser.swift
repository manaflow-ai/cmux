import Foundation

enum BrowserWebAuthnRequestParser {
    static let maximumKindUTF8Bytes = 64
    // The payload size is the bridge's only resource bound; it is decoded on
    // the main actor, so keep it small (Google's largest challenge is ~11 KB).
    // Per-field limits match Chromium, Firefox and WebKit: none caps challenges,
    // credential IDs, strings, transports or algorithms; all reject user IDs
    // over 64 bytes.
    static let maximumPayloadJSONUTF8Bytes = 1024 * 1024
    static let maximumInboundBinaryBytes = maximumPayloadJSONUTF8Bytes
    static let maximumInboundBase64URLCharacters = ((maximumInboundBinaryBytes + 2) / 3) * 4
    static let challengeByteRange = 1 ... maximumInboundBinaryBytes
    static let userIDByteRange = 1 ... 64
    static let credentialIDByteRange = 1 ... maximumInboundBinaryBytes
    // Chromium rejects more than 64 and Firefox more than 20.
    static let maximumCredentialDescriptors = 128
    static let maximumRelyingPartyIDUTF8Bytes = 253

    static func parseEnvelope(from body: Any) throws -> BrowserWebAuthnMessageEnvelope {
        guard let root = body as? [String: Any],
              let rawKind = root["kind"] as? String,
              rawKind.utf8.count <= maximumKindUTF8Bytes,
              let kind = BrowserWebAuthnBridgeMessageKind(rawValue: rawKind) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        let payloadJSON: String?
        if let rawPayload = root["payload"], !(rawPayload is NSNull) {
            guard let payload = rawPayload as? String,
                  payload.utf8.count <= maximumPayloadJSONUTF8Bytes else {
                throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
            }
            payloadJSON = payload
        } else {
            payloadJSON = nil
        }

        return .init(kind: kind, payloadJSON: payloadJSON)
    }

    static func decodePayload<T: Decodable>(
        _ type: T.Type,
        from envelope: BrowserWebAuthnMessageEnvelope
    ) throws -> T {
        guard let payloadJSON = envelope.payloadJSON,
              let payloadData = payloadJSON.data(using: .utf8) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        do {
            return try JSONDecoder().decode(T.self, from: payloadData)
        } catch {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }
    }
}
