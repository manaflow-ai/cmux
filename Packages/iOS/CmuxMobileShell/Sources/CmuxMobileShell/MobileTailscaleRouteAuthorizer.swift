import CMUXMobileCore
import CmuxMobilePairedMac

/// Owns the pure route-capability decisions used by pairing and reconnect.
///
/// The owner is deliberately constructable so a shell or a test can inject
/// the same policy without relying on ambient top-level functions.
public struct MobileTailscaleRouteAuthorizer: Sendable {
    /// The exact grants required when a Mac is pinned to Tailscale-only.
    struct Requirement: Sendable {
        let macDeviceID: String
        let grantRoutes: [CmxAttachRoute]
        let userGrantRoutes: [CmxAttachRoute]

        init(
            macDeviceID: String,
            grantRoutes: [CmxAttachRoute],
            userGrantRoutes: [CmxAttachRoute] = []
        ) {
            self.macDeviceID = macDeviceID
            self.grantRoutes = grantRoutes
            self.userGrantRoutes = userGrantRoutes
        }
    }

    /// Creates a stateless route-capability owner.
    public init() {}

    func userPairingAuthorization(
        for route: CmxAttachRoute,
        authorizations: Set<CmxUserTailscalePairingAuthorization>
    ) -> CmxUserTailscalePairingAuthorization? {
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint,
              let authorization = try? CmxUserTailscalePairingAuthorization(
                  host: host,
                  port: port
              ),
              authorizations.contains(authorization) else {
            return nil
        }
        return authorization
    }

    func userPairingAuthorization(
        for route: CmxAttachRoute,
        authorizations: [CmxUserTailscalePairingAuthorization]
    ) -> CmxUserTailscalePairingAuthorization? {
        userPairingAuthorization(for: route, authorizations: Set(authorizations))
    }

    func userPairingAuthorizations(
        from routes: [CmxAttachRoute]
    ) -> [CmxUserTailscalePairingAuthorization] {
        routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            return try? CmxUserTailscalePairingAuthorization(host: host, port: port)
        }
    }

    func userPairingAuthorizationsSet(
        from routes: [CmxAttachRoute]
    ) -> Set<CmxUserTailscalePairingAuthorization> {
        Set(userPairingAuthorizations(from: routes))
    }

    func userPairingAuthorization(
        for route: CmxAttachRoute,
        persistedRoutes: [CmxAttachRoute]
    ) -> CmxUserTailscalePairingAuthorization? {
        guard route.kind == .tailscale,
              case .hostPort = route.endpoint else {
            return nil
        }
        return userPairingAuthorization(
            for: route,
            authorizations: userPairingAuthorizationsSet(from: persistedRoutes)
        )
    }

    func explicitlyAuthorizedTailscaleRoutes(
        from routes: [CmxAttachRoute],
        authorizations: [CmxUserTailscalePairingAuthorization]
    ) -> [CmxAttachRoute] {
        let authorizedDestinations = Set(authorizations)
        return routes.filter {
            userPairingAuthorization(
                for: $0,
                authorizations: authorizedDestinations
            ) != nil
        }
    }

    func legacyAuthorizationSet(
        macDeviceID: String,
        from routes: [CmxAttachRoute]
    ) -> Set<CmxLegacyTailscaleAuthorizationEvidence> {
        Set(routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            return try? CmxLegacyTailscaleAuthorizationEvidence(
                macDeviceID: macDeviceID,
                host: host,
                port: port
            )
        })
    }

    func legacyAuthorizationEvidence(
        for route: CmxAttachRoute,
        macDeviceID: String,
        persistedAuthorizations: Set<CmxLegacyTailscaleAuthorizationEvidence>
    ) -> CmxLegacyTailscaleAuthorizationEvidence? {
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint,
              let candidate = try? CmxLegacyTailscaleAuthorizationEvidence(
                  macDeviceID: macDeviceID,
                  host: host,
                  port: port
              ),
              persistedAuthorizations.contains(candidate) else {
            return nil
        }
        return candidate
    }

    func legacyAuthorizationEvidence(
        for route: CmxAttachRoute,
        macDeviceID: String,
        persistedRoutes: [CmxAttachRoute]
    ) -> CmxLegacyTailscaleAuthorizationEvidence? {
        legacyAuthorizationEvidence(
            for: route,
            macDeviceID: macDeviceID,
            persistedAuthorizations: legacyAuthorizationSet(
                macDeviceID: macDeviceID,
                from: persistedRoutes
            )
        )
    }

    func hasAuthorizedTailscaleRoute(
        in routes: [CmxAttachRoute],
        macDeviceID: String,
        legacyRoutes: [CmxAttachRoute],
        userRoutes: [CmxAttachRoute]
    ) -> Bool {
        let legacyAuthorizations = legacyAuthorizationSet(
            macDeviceID: macDeviceID,
            from: legacyRoutes
        )
        let userAuthorizations = userPairingAuthorizationsSet(from: userRoutes)
        return routes.contains { route in
            legacyAuthorizationEvidence(
                for: route,
                macDeviceID: macDeviceID,
                persistedAuthorizations: legacyAuthorizations
            ) != nil
                || userPairingAuthorization(
                    for: route,
                    authorizations: userAuthorizations
                ) != nil
        }
    }

    func storedMacTicket(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            // Empty workspaceID deliberately requests the Mac-wide workspace
            // list; a synthetic id would be treated as a real scope.
            workspaceID: "",
            terminalID: nil,
            macDeviceID: pairedMacDeviceID,
            macDisplayName: name,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: routes
        )
    }
}
