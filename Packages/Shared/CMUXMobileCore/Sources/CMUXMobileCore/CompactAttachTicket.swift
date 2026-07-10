import Foundation

/// Compact short-key DTO for ``CmxAttachTicket``; see
/// ``CmxAttachTicketCompactCoder`` for the grammar and key map.
///
/// `JSONDecoder` ignores unknown keys, so payloads from the first compact
/// grammar revision that still carry `e` (expiry) and `n` (display name)
/// decode here with both intentionally dropped: a pairing QR never expires,
/// and the Mac's name is read post-handshake from `mobile.host.status`.
/// New Iroh pairing payloads disclose only EndpointID identity. The explicit
/// compatibility mode temporarily retains released clients' legacy routes.
struct CompactAttachTicket: Codable {
    let v: Int
    let w: String?
    let t: String?
    let d: String
    let u: String?
    let pc: Int?
    let av: String?
    let ab: String?
    let r: [CompactAttachRoute]

    init(
        _ ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode
    ) throws {
        let disclosedRoutes = Self.disclosedRoutes(
            ticket.routes,
            mode: routeDisclosureMode
        )
        guard !disclosedRoutes.isEmpty else {
            throw CmxAttachTicketCompactCoderError.noRoutesForDisclosureMode(
                routeDisclosureMode
            )
        }
        v = ticket.version
        w = Self.normalizedNonEmpty(ticket.workspaceID)
        t = Self.normalizedNonEmpty(ticket.terminalID)
        d = ticket.macDeviceID
        u = Self.normalizedNonEmpty(ticket.macUserID)
        pc = ticket.macPairingCompatibilityVersion
        av = Self.normalizedNonEmpty(ticket.macAppVersion)
        ab = Self.normalizedNonEmpty(ticket.macAppBuild)
        r = Self.compactedRoutes(disclosedRoutes)
    }

    func ticket() throws -> CmxAttachTicket {
        try CmxAttachTicket(
            version: v,
            workspaceID: w ?? "",
            terminalID: t,
            macDeviceID: d,
            macDisplayName: nil,
            macUserEmail: u?.contains("@") == true ? u : nil,
            macUserID: u?.contains("@") == false ? u : nil,
            macPairingCompatibilityVersion: pc ?? 0,
            macAppVersion: av,
            macAppBuild: ab,
            routes: Self.expandedRoutes(r),
            expiresAt: nil
        )
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

}

private extension CompactAttachTicket {
    static func disclosedRoutes(
        _ routes: [CmxAttachRoute],
        mode: CmxPairingRouteDisclosureMode
    ) -> [CmxAttachRoute] {
        switch mode {
        case .irohIdentityOnly:
            return routes.compactMap { route in
                guard route.kind == .iroh,
                      case let .peer(identity, _) = route.endpoint else {
                    return nil
                }
                return try? CmxAttachRoute(
                    id: route.id,
                    kind: route.kind,
                    endpoint: .peer(identity: identity, pathHints: []),
                    priority: route.priority
                )
            }
        case .legacyPrivateNetworkCompatibility:
            return routes
        }
    }

    /// Encode routes, omitting each route id the decoder can resynthesize
    /// (`kind` for the first route of a kind, `kind_N` for the Nth; exactly
    /// the ids the Mac's route resolver mints). Ids that differ are kept, so
    /// the mapping is lossless for every ticket.
    static func compactedRoutes(_ routes: [CmxAttachRoute]) -> [CompactAttachRoute] {
        var kindCounts: [CmxAttachTransportKind: Int] = [:]
        return routes.map { route in
            let occurrence = (kindCounts[route.kind] ?? 0) + 1
            kindCounts[route.kind] = occurrence
            let synthesized = synthesizedRouteID(kind: route.kind, occurrence: occurrence)
            return CompactAttachRoute(route, omittingID: route.id == synthesized)
        }
    }

    /// Decode routes, resynthesizing each omitted route id with the same
    /// `kind` / `kind_N` rule the encoder applied.
    static func expandedRoutes(_ compactRoutes: [CompactAttachRoute]) throws -> [CmxAttachRoute] {
        var kindCounts: [CmxAttachTransportKind: Int] = [:]
        return try compactRoutes.map { compactRoute in
            let kind = try compactRoute.kind()
            let occurrence = (kindCounts[kind] ?? 0) + 1
            kindCounts[kind] = occurrence
            return try compactRoute.route(
                synthesizedID: synthesizedRouteID(kind: kind, occurrence: occurrence)
            )
        }
    }

    /// The route id the Mac's route resolver mints for the `occurrence`-th
    /// route of `kind` (`kind` for the first, `kind_N` after).
    static func synthesizedRouteID(
        kind: CmxAttachTransportKind,
        occurrence: Int
    ) -> String {
        occurrence == 1 ? kind.rawValue : "\(kind.rawValue)_\(occurrence)"
    }
}
