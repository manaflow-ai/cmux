import Foundation

/// Codes ``CmxAttachTicket`` to and from the compact wire form used by the
/// pairing QR payload.
///
/// The pairing QR encodes `cmux-ios://attach?v=1&payload=<base64url(JSON)>`.
/// The legacy JSON spelled out full camelCase keys plus a vestigial
/// `auth_token`, which pushed the QR into a denser version than necessary.
/// The compact grammar keeps the same envelope and the same field semantics
/// but uses short keys, drops empty optional fields, encodes the expiry as
/// whole unix seconds, and omits the auth token entirely (the mobile host
/// treats the owner's Stack access token as the sole authorization gate; see
/// `MobileHostService.authorizationError(for:)`).
///
/// Compatibility:
/// - New decoders accept both grammars: ``CmxAttachTicketInput`` routes a
///   payload whose top-level object carries `"v"` here and everything else
///   (legacy `"version"` payloads) through the original `Codable` path.
/// - Old decoders reject the compact grammar loudly (a `DecodingError` from
///   the missing `"version"` key), so an outdated phone scanning a new QR
///   shows a pairing error instead of silently misreading the ticket.
///
/// Key map (ticket): `v` version, `w` workspaceID (omitted when empty),
/// `t` terminalID, `d` macDeviceID, `n` macDisplayName, `e` expiry (unix
/// seconds), `r` routes.
/// Key map (route): `i` id, `k` kind raw value, `p` priority (omitted when 0),
/// `e` endpoint.
/// Key map (endpoint): `t` type raw value (`host_port`/`peer`/`url`), then
/// `h` host + `p` port, or `i` peer id + `rh` relay hint + `da` direct addrs +
/// `ru` relay URL, or `u` url.
public struct CmxAttachTicketCompactCoder: Sendable {
    /// Creates a coder. The coder is stateless; instances are interchangeable.
    public init() {}

    /// Encode a ticket into the compact JSON grammar.
    ///
    /// Any `authToken` on the ticket is intentionally not encoded: the token
    /// never authorizes anything on the host (Stack auth is the sole gate),
    /// so carrying it in the QR only inflated the payload.
    public func encode(_ ticket: CmxAttachTicket) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CompactAttachTicket(ticket))
    }

    /// Decode a compact JSON payload into a validated ``CmxAttachTicket``.
    public func decode(_ data: Data) throws -> CmxAttachTicket {
        try JSONDecoder().decode(CompactAttachTicket.self, from: data).ticket()
    }

    /// Whether a decoded `payload` blob speaks the compact grammar.
    ///
    /// Compact payloads carry the version under `"v"`; legacy payloads carry
    /// it under `"version"`. Non-JSON input returns `false` so the caller
    /// falls through to the legacy decoder, which throws a proper error.
    public func isCompactPayload(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["v"] != nil
    }
}
