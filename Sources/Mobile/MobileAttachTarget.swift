import CMUXMobileCore
import Foundation

/// The consumer of a newly minted attach ticket. The destination owns route
/// selection and URL representation so simulator and phone policies cannot be
/// accidentally interchanged after the route set has been minted.
enum MobileAttachTarget: String, Sendable {
    case ticketOnly = "ticket_only"
    case simulatorInjection = "simulator_injection"
    case physicalDevice = "physical_device"

    init?(wireValue: String) {
        self.init(rawValue: wireValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    func selectRoutes(from routes: [CmxAttachRoute]) throws -> [CmxAttachRoute] {
        guard !routes.isEmpty else { throw MobileAttachTicketStoreError.noRoutes }
        let selected: [CmxAttachRoute]
        switch self {
        case .ticketOnly:
            selected = routes
        case .simulatorInjection:
            selected = routes.filter { route in
                route.kind == .debugLoopback && CmxLoopbackHost().matches(route)
            }
        case .physicalDevice:
            selected = try Self.canonicalTailscaleRoutes(from: routes)
        }
        guard !selected.isEmpty else {
            throw MobileAttachTicketStoreError.routeUnavailable
        }
        return selected
    }

    /// The non-loopback Tailscale routes of `routes`, reindexed to the
    /// canonical id/priority sequence the v2 pairing decoder resynthesizes.
    ///
    /// A route-id filter can leave `tailscale_2` as the only route, and mixed
    /// snapshots interleave loopback entries. Reindexing keeps the
    /// disclosed subsequence expressible in the bare `host:port` grammar
    /// (which encodes neither ids nor priorities) without a token-bearing v1
    /// fallback. Shared by the physical-device destination and the pairing
    /// window's Tailscale compatibility code.
    static func canonicalTailscaleRoutes(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        try routes
            .filter { $0.kind == .tailscale && !CmxLoopbackHost().matches($0) }
            .enumerated().map { index, route in
                try CmxAttachRoute(
                    id: index == 0
                        ? CmxAttachTransportKind.tailscale.rawValue
                        : "\(CmxAttachTransportKind.tailscale.rawValue)_\(index + 1)",
                    kind: .tailscale,
                    endpoint: route.endpoint,
                    priority: 10 + index * 10
                )
            }
    }

}

extension Optional where Wrapped == MobileAttachTarget {
    /// A missing target preserves the legacy full-route ticket contract.
    func selectRoutes(from routes: [CmxAttachRoute]) throws -> [CmxAttachRoute] {
        guard let target = self else {
            guard !routes.isEmpty else { throw MobileAttachTicketStoreError.noRoutes }
            return routes
        }
        return try target.selectRoutes(from: routes)
    }
}
