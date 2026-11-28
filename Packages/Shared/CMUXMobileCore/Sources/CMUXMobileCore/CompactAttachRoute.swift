import Foundation

/// Compact short-key DTO for ``CmxAttachRoute``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
///
/// The route id is omitted on encode whenever it equals the id the decoder
/// resynthesizes from the route's kind and position (``CompactAttachTicket``
/// owns that mapping), and is honored verbatim when present, so both the new
/// id-free payloads and the first compact revision's explicit-id payloads
/// decode to the same routes.
struct CompactAttachRoute: Codable {
    let i: String?
    let k: String
    let p: Int?
    let e: CompactAttachEndpoint

    init(_ route: CmxAttachRoute, omittingID: Bool) {
        i = omittingID ? nil : route.id
        k = route.kind.rawValue
        p = route.priority == 0 ? nil : route.priority
        e = CompactAttachEndpoint(route.endpoint)
    }

    func kind() throws -> CmxAttachTransportKind {
        guard let kind = CmxAttachTransportKind(rawValue: k) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown attach route kind: \(k)"
            ))
        }
        return kind
    }

    func route(synthesizedID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: i ?? synthesizedID,
            kind: kind(),
            endpoint: e.endpoint(),
            priority: p ?? 0
        )
    }
}
