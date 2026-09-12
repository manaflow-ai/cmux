public import CMUXMobileCore

/// Selects and canonicalizes authenticated routes for mobile pairing artifacts.
///
/// The planner owns only value transformations. Ticket issuance, host identity,
/// authentication, and persistence remain in the executable app target.
public struct CmxMobileAttachRoutePlanner: Sendable {
    private let canonicalizer: CmxMobileAttachRouteCanonicalizer

    /// Creates a stateless route planner.
    public init() {
        canonicalizer = CmxMobileAttachRouteCanonicalizer()
    }

    /// Selects the route subset appropriate for a ticket consumer.
    ///
    /// - Parameters:
    ///   - target: The consumer target, or `nil` for the legacy full-route form.
    ///   - routes: Authenticated routes advertised by the Mac.
    /// - Returns: Routes safe for the requested consumer.
    /// - Throws: ``CmxMobileAttachRoutePlanningError`` when no usable subset exists.
    public func selectRoutes(
        for target: CmxMobileAttachTarget?,
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        guard !routes.isEmpty else {
            throw CmxMobileAttachRoutePlanningError.noRoutes
        }
        guard let target else { return routes }

        let selected: [CmxAttachRoute]
        switch target {
        case .ticketOnly:
            selected = routes
        case .simulatorInjection:
            let irohRoutes = try canonicalizer.identityOnlyIrohRoutes(from: routes)
            selected = irohRoutes.isEmpty
                ? routes.filter { route in
                    route.kind == .debugLoopback && CmxLoopbackHost().matches(route)
                }
                : irohRoutes
        case .physicalDevice:
            let irohRoutes = try canonicalizer.identityOnlyIrohRoutes(from: routes)
            let tailscaleRoutes = try canonicalTailscaleRoutes(from: routes)
            let lanRoutes = try canonicalLANRoutes(from: routes)
            guard !irohRoutes.isEmpty || !tailscaleRoutes.isEmpty else {
                // A raw LAN route cannot bootstrap an authenticated phone by
                // itself; require Iroh identity or Tailscale compatibility.
                throw CmxMobileAttachRoutePlanningError.routeUnavailable
            }
            selected = irohRoutes + lanRoutes + tailscaleRoutes
        }

        guard !selected.isEmpty else {
            throw CmxMobileAttachRoutePlanningError.routeUnavailable
        }
        return selected
    }

    /// Reindexes non-loopback Tailscale routes to the compact pairing grammar.
    ///
    /// - Parameter routes: The advertised route snapshot.
    /// - Returns: Canonical Tailscale routes in stable priority order.
    /// - Throws: ``CmxMobileAttachRoutePlanningError.invalidRoute`` if a route
    ///   cannot be reconstructed.
    public func canonicalTailscaleRoutes(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        try canonicalizer.canonicalRoutes(
            from: routes,
            kind: .tailscale,
            firstPriority: 10,
            priorityStep: 10
        )
    }

    /// Reindexes non-loopback LAN routes to the compact pairing grammar.
    ///
    /// - Parameter routes: The advertised route snapshot.
    /// - Returns: Canonical LAN routes in stable priority order.
    /// - Throws: ``CmxMobileAttachRoutePlanningError.invalidRoute`` if a route
    ///   cannot be reconstructed.
    public func canonicalLANRoutes(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        try canonicalizer.canonicalRoutes(
            from: routes,
            kind: .lan,
            firstPriority: 5,
            priorityStep: 10
        )
    }
}
