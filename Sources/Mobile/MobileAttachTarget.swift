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
            let irohRoutes = try Self.identityOnlyIrohRoutes(from: routes)
            selected = irohRoutes.isEmpty
                ? routes.filter { route in
                    route.kind == .debugLoopback && CmxLoopbackHost().matches(route)
                }
                : irohRoutes
        case .physicalDevice:
            let irohRoutes = try Self.identityOnlyIrohRoutes(from: routes)
            let tailscaleRoutes = try Self.canonicalTailscaleRoutes(from: routes)
            let lanRoutes = try Self.canonicalLANRoutes(from: routes)
            guard !irohRoutes.isEmpty || !tailscaleRoutes.isEmpty else {
                // A raw LAN route cannot bootstrap an authenticated phone
                // session by itself; require Iroh identity or Tailscale
                // compatibility before minting a physical-device payload.
                throw MobileAttachTicketStoreError.routeUnavailable
            }
            // Keep every explicitly advertised network class alongside the
            // identity-only Iroh route. The iPhone's pinned mode filters this
            // set after pairing; dropping LAN/Tailscale here would make those
            // modes impossible whenever the Mac also has Iroh online.
            selected = irohRoutes + lanRoutes + tailscaleRoutes
        }
        guard !selected.isEmpty else {
            throw MobileAttachTicketStoreError.routeUnavailable
        }
        return selected
    }

    /// Returns physical-device QR routes that every released route grammar can
    /// understand while retaining an encrypted bootstrap for current pinned
    /// modes. The legacy compact decoder knows Iroh and Tailscale but not the
    /// newer `.lan` kind, so LAN metadata is recovered from authenticated host
    /// status after the first connection instead of being placed in the QR.
    static func physicalDeviceCompatibilityQRRoutes(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        let selected = try physicalDevice.selectRoutes(from: routes)
        let compatible = selected.filter { $0.kind != .lan }
        guard !compatible.isEmpty else {
            throw MobileAttachTicketStoreError.routeUnavailable
        }
        return compatible
    }

    /// The non-loopback Tailscale routes of `routes`, reindexed to the
    /// canonical id/priority sequence the v2 pairing decoder resynthesizes.
    ///
    /// A route-id filter can leave `tailscale_2` as the only route, and mixed
    /// snapshots interleave Iroh and loopback entries. Reindexing keeps the
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

    /// The non-loopback LAN routes of `routes`, reindexed for compact pairing
    /// payloads that synthesize IDs from route class and position.
    static func canonicalLANRoutes(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        try routes
            .filter { $0.kind == .lan && !CmxLoopbackHost().matches($0) }
            .enumerated().map { index, route in
                try CmxAttachRoute(
                    id: index == 0
                        ? CmxAttachTransportKind.lan.rawValue
                        : "\(CmxAttachTransportKind.lan.rawValue)_\(index + 1)",
                    kind: .lan,
                    endpoint: route.endpoint,
                    priority: 5 + index * 5
                )
            }
    }

    private static func identityOnlyIrohRoutes(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        try routes.compactMap { route in
            guard route.kind == .iroh,
                  case let .peer(identity, _) = route.endpoint else {
                return nil
            }
            return try CmxAttachRoute(
                id: route.id,
                kind: .iroh,
                endpoint: .peer(identity: identity, pathHints: []),
                priority: route.priority
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
