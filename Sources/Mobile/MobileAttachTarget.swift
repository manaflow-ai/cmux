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
            guard irohRoutes.isEmpty else {
                selected = irohRoutes
                break
            }
            let physicalRoutes = routes.filter {
                $0.kind == .tailscale && !CmxLoopbackHost().matches($0)
            }
            // A route-id filter can leave `tailscale_2` as the only route.
            // Reindex the selected endpoints to the canonical sequence the v2
            // QR decoder reconstructs, keeping the destination lossless while
            // avoiding a token-bearing v1 fallback on physical devices.
            selected = try physicalRoutes.enumerated().map { index, route in
                try CmxAttachRoute(
                    id: index == 0 ? "tailscale" : "tailscale_\(index + 1)",
                    kind: .tailscale,
                    endpoint: route.endpoint,
                    priority: 10 + index * 10
                )
            }
        }
        guard !selected.isEmpty else {
            throw MobileAttachTicketStoreError.routeUnavailable
        }
        return selected
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
