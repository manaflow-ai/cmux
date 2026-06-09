import Foundation

/// Compact wire form of ``CmxAttachTicket`` for the pairing QR payload.
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
public enum CmxAttachTicketCompactCoding {
    /// Encode a ticket into the compact JSON grammar.
    ///
    /// Any `authToken` on the ticket is intentionally not encoded: the token
    /// never authorizes anything on the host (Stack auth is the sole gate),
    /// so carrying it in the QR only inflated the payload.
    public static func encode(_ ticket: CmxAttachTicket) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(CompactTicket(ticket))
    }

    /// Decode a compact JSON payload into a validated ``CmxAttachTicket``.
    public static func decode(_ data: Data) throws -> CmxAttachTicket {
        try JSONDecoder().decode(CompactTicket.self, from: data).ticket()
    }

    /// Whether a decoded `payload` blob speaks the compact grammar.
    ///
    /// Compact payloads carry the version under `"v"`; legacy payloads carry
    /// it under `"version"`. Non-JSON input returns `false` so the caller
    /// falls through to the legacy decoder, which throws a proper error.
    public static func isCompactPayload(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["v"] != nil
    }
}

private struct CompactTicket: Codable {
    let v: Int
    let w: String?
    let t: String?
    let d: String
    let n: String?
    let e: Int
    let r: [CompactRoute]

    init(_ ticket: CmxAttachTicket) {
        v = ticket.version
        w = Self.normalized(ticket.workspaceID)
        t = Self.normalized(ticket.terminalID)
        d = ticket.macDeviceID
        n = Self.normalized(ticket.macDisplayName)
        // Round up so the compact form never shortens the ticket's lifetime.
        e = Int(ticket.expiresAt.timeIntervalSince1970.rounded(.up))
        r = ticket.routes.map(CompactRoute.init)
    }

    func ticket() throws -> CmxAttachTicket {
        try CmxAttachTicket(
            version: v,
            workspaceID: w ?? "",
            terminalID: t,
            macDeviceID: d,
            macDisplayName: n,
            routes: r.map { try $0.route() },
            expiresAt: Date(timeIntervalSince1970: TimeInterval(e))
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct CompactRoute: Codable {
    let i: String
    let k: String
    let p: Int?
    let e: CompactEndpoint

    init(_ route: CmxAttachRoute) {
        i = route.id
        k = route.kind.rawValue
        p = route.priority == 0 ? nil : route.priority
        e = CompactEndpoint(route.endpoint)
    }

    func route() throws -> CmxAttachRoute {
        guard let kind = CmxAttachTransportKind(rawValue: k) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown attach route kind: \(k)"
            ))
        }
        return try CmxAttachRoute(
            id: i,
            kind: kind,
            endpoint: e.endpoint(),
            priority: p ?? 0
        )
    }
}

private struct CompactEndpoint: Codable {
    let t: String
    let h: String?
    let p: Int?
    let i: String?
    let rh: String?
    let da: [String]?
    let ru: String?
    let u: String?

    init(_ endpoint: CmxAttachEndpoint) {
        switch endpoint {
        case let .hostPort(host, port):
            t = "host_port"
            h = host
            p = port
            i = nil
            rh = nil
            da = nil
            ru = nil
            u = nil
        case let .peer(id, relayHint, directAddrs, relayURL):
            t = "peer"
            h = nil
            p = nil
            i = id
            rh = relayHint
            da = directAddrs.isEmpty ? nil : directAddrs
            ru = relayURL
            u = nil
        case let .url(url):
            t = "url"
            h = nil
            p = nil
            i = nil
            rh = nil
            da = nil
            ru = nil
            u = url
        }
    }

    func endpoint() throws -> CmxAttachEndpoint {
        switch t {
        case "host_port":
            guard let h, let p else {
                throw Self.corrupted("host_port endpoint requires h and p")
            }
            return .hostPort(host: h, port: p)
        case "peer":
            guard let i else {
                throw Self.corrupted("peer endpoint requires i")
            }
            return .peer(id: i, relayHint: rh, directAddrs: da ?? [], relayURL: ru)
        case "url":
            guard let u else {
                throw Self.corrupted("url endpoint requires u")
            }
            return .url(u)
        default:
            throw Self.corrupted("Unknown attach endpoint type: \(t)")
        }
    }

    private static func corrupted(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: [],
            debugDescription: message
        ))
    }
}
