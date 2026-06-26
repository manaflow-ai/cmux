import Foundation

/// Codes ``CmxAttachTicket`` to and from the compact wire form used by the
/// pairing QR payload.
///
/// The pairing QR encodes `cmux-ios://attach?v=1&payload=<base64url(JSON)>`.
/// The legacy JSON spelled out full camelCase keys plus a vestigial
/// `auth_token`, which pushed the QR into a denser version than necessary.
/// The compact grammar keeps the same envelope but encodes only what pairing
/// actually consumes: short keys, no empty optional fields, no auth token, no
/// display name (read post-handshake from `mobile.host.status`), and no
/// inline expiry. It does keep non-secret pairing context: the ticket reference,
/// Mac account id, shared pairing compatibility level, and app version/build,
/// so the phone can redeem the host-side ticket record after Stack auth, fail
/// fast on an account mismatch, and warn before continuing across compatibility
/// skew. The ticket reference is not a bearer credential; the owner's Stack
/// access token is the host's authorization gate.
///
/// Compatibility:
/// - New decoders accept both grammars: ``CmxAttachTicketInput`` routes a
///   payload whose top-level object carries `"v"` here and everything else
///   (legacy `"version"` payloads) through the original `Codable` path.
/// - Payloads from the first compact revision still decode: their extra `e`
///   (expiry) and `n` (display name) keys are ignored, their explicit route
///   `i` ids and endpoint `t` types are honored.
/// - Old decoders reject the compact grammar loudly (a `DecodingError` from
///   the missing `"version"` key), so an outdated phone scanning a new QR
///   shows a pairing error instead of silently misreading the ticket.
///
/// Key map (ticket): `v` version, `w` workspaceID (omitted when empty),
/// `t` terminalID, `d` macDeviceID, `u` Mac account id, `pc` pairing
/// compatibility version, `av` app version, `ab` app build, `q` ticket
/// reference, `r` routes.
/// Key map (route): `i` id (omitted when the decoder can resynthesize it:
/// `kind` for the first route of a kind, `kind_N` for the Nth), `k` kind raw
/// value, `p` priority (omitted when 0), `e` endpoint.
/// Key map (endpoint): the type is implied by the keys present (accepted
/// explicitly under `t` for first-revision payloads): `h` host + `p` port, or
/// `i` peer id + `rh` relay hint + `da` direct addrs + `ru` relay URL, or
/// `u` url.
public struct CmxAttachTicketCompactCoder: Sendable {
    /// Creates a coder. The coder is stateless; instances are interchangeable.
    public init() {}

    /// Encode a ticket into the compact JSON grammar.
    ///
    /// Any `authToken`, `macDisplayName`, and `expiresAt` on the ticket are
    /// intentionally not encoded: the token is resolved from `ticketRef` only
    /// after Stack auth, the name is read post-handshake from
    /// `mobile.host.status`, and the host-side ticket record owns expiry.
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
