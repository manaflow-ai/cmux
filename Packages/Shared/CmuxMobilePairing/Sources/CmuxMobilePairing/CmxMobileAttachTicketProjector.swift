public import CMUXMobileCore

/// Projects an authenticated attach ticket into a consumer-specific pairing form.
///
/// The projector owns only bounded value transformations. It never issues
/// credentials, reads persistence, or decides whether a caller is authorized to
/// connect; those responsibilities remain in the host application.
public struct CmxMobileAttachTicketProjector: Sendable {
    /// Creates a stateless ticket projector.
    public init() {}

    /// Keeps every route class a current physical iPhone can use.
    ///
    /// Iroh path hints are discovery coordinates rather than pairing authority,
    /// so they are removed while the authenticated EndpointID is retained.
    /// Token material is omitted because the QR bootstrap is identity-based.
    /// - Parameters:
    ///   - ticket: The authenticated ticket to project.
    ///   - routes: The route subset selected for the physical device.
    /// - Returns: A compact-ticket-ready value retaining the selected routes.
    /// - Throws: ``CmxMobileAttachRoutePlanningError/routeUnavailable`` when
    ///   no route survives projection.
    public func physicalDeviceTicket(
        _ ticket: CmxAttachTicket,
        routes: [CmxAttachRoute]
    ) throws -> CmxAttachTicket {
        let sanitizedRoutes = try stripIrohPathHints(from: routes)
        return try copy(
            ticket,
            routes: sanitizedRoutes,
            preserveAccountEmail: true,
            preserveExpiry: true,
            preserveAuthToken: false
        )
    }

    /// Projects the legacy authenticated ticket response for released decoders.
    ///
    /// The older route-kind grammar cannot represent LAN, so LAN routes are
    /// omitted while all other authenticated fields, including the bearer token,
    /// remain intact.
    /// - Parameter ticket: The current authenticated ticket.
    /// - Returns: A ticket containing only released-decoder route kinds.
    /// - Throws: ``CmxMobileAttachRoutePlanningError/routeUnavailable`` when
    ///   filtering would leave no compatible route.
    public func ticketOnlyCompatibilityTicket(
        _ ticket: CmxAttachTicket
    ) throws -> CmxAttachTicket {
        let routes = ticket.routes.filter { $0.kind != .lan }
        guard !routes.isEmpty else {
            throw CmxMobileAttachRoutePlanningError.routeUnavailable
        }
        return try copy(
            ticket,
            routes: routes,
            preserveAccountEmail: true,
            preserveExpiry: true,
            preserveAuthToken: true
        )
    }

    /// Builds a released-client Tailscale compatibility ticket.
    ///
    /// Only canonical, non-loopback Tailscale host routes are retained. The
    /// output is token-free and non-expiring because the QR is a pairing hint,
    /// not a bearer credential.
    /// - Parameter ticket: The current authenticated ticket.
    /// - Returns: A canonical Tailscale-only compatibility ticket, or `nil` when
    ///   the ticket cannot be represented by the v2 grammar.
    public func tailscaleCompatibilityTicket(
        _ ticket: CmxAttachTicket
    ) -> CmxAttachTicket? {
        guard let routes = try? CmxMobileAttachRoutePlanner().canonicalTailscaleRoutes(
            from: ticket.routes
        ), !routes.isEmpty else {
            return nil
        }
        return try? copy(
            ticket,
            routes: routes,
            preserveAccountEmail: false,
            preserveExpiry: true,
            preserveAuthToken: false
        )
    }

    /// Whether a route set contains exactly one hint-free Iroh identity route.
    public func hasOnlyIdentityOnlyIrohRoutes(
        _ routes: [CmxAttachRoute]
    ) -> Bool {
        !routes.isEmpty && routes.allSatisfy { route in
            guard route.kind == .iroh,
                  case let .peer(_, pathHints) = route.endpoint else {
                return false
            }
            return pathHints.isEmpty
        }
    }

    /// Removes route data that a compact pairing disclosure cannot represent.
    ///
    /// Identity-only mode keeps only Iroh peer identities. Legacy private-network
    /// mode keeps LAN out of the released grammar and strips Iroh path hints;
    /// callers that need a lossless current-client physical projection should
    /// use ``physicalDeviceTicket(_:routes:)`` instead.
    /// - Parameters:
    ///   - ticket: The ticket to project.
    ///   - disclosureMode: The compact pairing disclosure grammar.
    /// - Returns: A token-free, non-expiring compact-ticket value.
    /// - Throws: ``CmxMobileAttachRoutePlanningError/routeUnavailable`` when no
    ///   route can be encoded in the requested grammar.
    public func legacyCompactTicket(
        _ ticket: CmxAttachTicket,
        disclosureMode: CmxPairingRouteDisclosureMode
    ) throws -> CmxAttachTicket {
        let routes = ticket.routes.compactMap { route -> CmxAttachRoute? in
            switch disclosureMode {
            case .irohIdentityOnly:
                guard route.kind == .iroh,
                      case let .peer(identity, _) = route.endpoint else {
                    return nil
                }
                return try? CmxAttachRoute(
                    id: route.id,
                    kind: .iroh,
                    endpoint: .peer(identity: identity, pathHints: []),
                    priority: route.priority
                )
            case .legacyPrivateNetworkCompatibility:
                guard route.kind != .lan else { return nil }
                guard route.kind == .iroh else { return route }
                guard case let .peer(identity, _) = route.endpoint else { return nil }
                return try? CmxAttachRoute(
                    id: route.id,
                    kind: .iroh,
                    endpoint: .peer(identity: identity, pathHints: []),
                    priority: route.priority
                )
            }
        }
        guard !routes.isEmpty else {
            throw CmxMobileAttachRoutePlanningError.routeUnavailable
        }
        return try copy(
            ticket,
            routes: routes,
            preserveAccountEmail: false,
            preserveExpiry: false,
            preserveAuthToken: false
        )
    }

    private func stripIrohPathHints(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        let sanitized = routes.compactMap { route -> CmxAttachRoute? in
            guard route.kind == .iroh else { return route }
            guard case let .peer(identity, _) = route.endpoint else { return nil }
            return try? CmxAttachRoute(
                id: route.id,
                kind: .iroh,
                endpoint: .peer(identity: identity, pathHints: []),
                priority: route.priority
            )
        }
        guard !sanitized.isEmpty else {
            throw CmxMobileAttachRoutePlanningError.routeUnavailable
        }
        return sanitized
    }

    private func copy(
        _ ticket: CmxAttachTicket,
        routes: [CmxAttachRoute],
        preserveAccountEmail: Bool,
        preserveExpiry: Bool,
        preserveAuthToken: Bool
    ) throws -> CmxAttachTicket {
        guard !routes.isEmpty else {
            throw CmxMobileAttachRoutePlanningError.routeUnavailable
        }
        return try CmxAttachTicket(
            version: ticket.version,
            workspaceID: ticket.workspaceID,
            terminalID: ticket.terminalID,
            macDeviceID: ticket.macDeviceID,
            macDisplayName: ticket.macDisplayName,
            macUserEmail: preserveAccountEmail ? ticket.macUserEmail : nil,
            macUserID: ticket.macUserID,
            macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
            macAppVersion: ticket.macAppVersion,
            macAppBuild: ticket.macAppBuild,
            routes: routes,
            expiresAt: preserveExpiry ? ticket.expiresAt : nil,
            authToken: preserveAuthToken ? ticket.authToken : nil
        )
    }
}
