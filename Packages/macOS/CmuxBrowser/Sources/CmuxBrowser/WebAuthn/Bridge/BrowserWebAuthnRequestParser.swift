import Foundation

/// Parses raw `cmuxWebAuthn` message-handler bodies into typed bridge envelopes
/// and decodes their JSON payloads into the matching request models.
public struct BrowserWebAuthnRequestParser {
    public init() {}

    /// Parses a raw message body into an envelope, throwing a `TypeError` bridge
    /// error when the body is not a well-formed bridge message.
    public func parseEnvelope(from body: Any) throws -> BrowserWebAuthnMessageEnvelope {
        guard let root = body as? [String: Any],
              let rawKind = root["kind"] as? String,
              let kind = BrowserWebAuthnBridgeMessageKind(rawValue: rawKind) else {
            throw BrowserWebAuthnBridgeError.type("Malformed browser passkey request.")
        }

        return .init(kind: kind, payloadJSON: root["payload"] as? String)
    }

    /// Decodes an envelope's JSON payload into the requested `Decodable` model,
    /// throwing a `TypeError` bridge error when the payload is missing or invalid.
    public func decodePayload<T: Decodable>(
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
