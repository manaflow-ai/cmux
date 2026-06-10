import Foundation

/// Compact short-key DTO for ``CmxAttachRoute``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
struct CompactAttachRoute: Codable {
    let i: String
    let k: String
    let p: Int?
    let e: CompactAttachEndpoint

    init(_ route: CmxAttachRoute) {
        i = route.id
        k = route.kind.rawValue
        p = route.priority == 0 ? nil : route.priority
        e = CompactAttachEndpoint(route.endpoint)
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
