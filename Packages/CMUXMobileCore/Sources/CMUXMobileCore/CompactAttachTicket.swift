import Foundation

/// Compact short-key DTO for ``CmxAttachTicket``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
struct CompactAttachTicket: Codable {
    let v: Int
    let w: String?
    let t: String?
    let d: String
    let n: String?
    let e: Int
    let r: [CompactAttachRoute]

    init(_ ticket: CmxAttachTicket) {
        v = ticket.version
        w = normalizedNonEmpty(ticket.workspaceID)
        t = normalizedNonEmpty(ticket.terminalID)
        d = ticket.macDeviceID
        n = normalizedNonEmpty(ticket.macDisplayName)
        // Round up so the compact form never shortens the ticket's lifetime.
        e = Int(ticket.expiresAt.timeIntervalSince1970.rounded(.up))
        r = ticket.routes.map(CompactAttachRoute.init)
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
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}
