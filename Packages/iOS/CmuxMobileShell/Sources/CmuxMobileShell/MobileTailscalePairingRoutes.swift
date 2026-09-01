import CMUXMobileCore
import CmuxMobilePairedMac

/// Pure route/capability helpers shared by pairing and reconnect flows.
/// Keeping these operations at file scope makes their authorization inputs
/// explicit and prevents a stateful shell type from becoming a utility bag.

func cmuxUserTailscalePairingAuthorization(
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

func cmuxUserTailscalePairingAuthorization(
    for route: CmxAttachRoute,
    authorizations: [CmxUserTailscalePairingAuthorization]
) -> CmxUserTailscalePairingAuthorization? {
    cmuxUserTailscalePairingAuthorization(
        for: route,
        authorizations: Set(authorizations)
    )
}

func cmuxUserTailscalePairingAuthorizations(
    from routes: [CmxAttachRoute]
) -> [CmxUserTailscalePairingAuthorization] {
    routes.compactMap { route in
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint else { return nil }
        return try? CmxUserTailscalePairingAuthorization(host: host, port: port)
    }
}

func cmuxUserTailscalePairingAuthorizationsSet(
    from routes: [CmxAttachRoute]
) -> Set<CmxUserTailscalePairingAuthorization> {
    Set(cmuxUserTailscalePairingAuthorizations(from: routes))
}

func cmuxUserTailscalePairingAuthorization(
    for route: CmxAttachRoute,
    persistedRoutes: [CmxAttachRoute]
) -> CmxUserTailscalePairingAuthorization? {
    guard route.kind == .tailscale,
          case .hostPort = route.endpoint else { return nil }
    return cmuxUserTailscalePairingAuthorization(
        for: route,
        authorizations: cmuxUserTailscalePairingAuthorizationsSet(
            from: persistedRoutes
        )
    )
}

func cmuxExplicitlyAuthorizedTailscaleRoutes(
    from routes: [CmxAttachRoute],
    authorizations: [CmxUserTailscalePairingAuthorization]
) -> [CmxAttachRoute] {
    let authorizedDestinations = Set(authorizations)
    let matches = routes.filter { route in
        cmuxUserTailscalePairingAuthorization(
            for: route,
            authorizations: authorizedDestinations
        ) != nil
    }
    return matches
}

func cmuxLegacyTailscaleAuthorizationSet(
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

func cmuxLegacyTailscaleAuthorizationEvidence(
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

func cmuxLegacyTailscaleAuthorizationEvidence(
    for route: CmxAttachRoute,
    macDeviceID: String,
    persistedRoutes: [CmxAttachRoute]
) -> CmxLegacyTailscaleAuthorizationEvidence? {
    cmuxLegacyTailscaleAuthorizationEvidence(
        for: route,
        macDeviceID: macDeviceID,
        persistedAuthorizations: cmuxLegacyTailscaleAuthorizationSet(
            macDeviceID: macDeviceID,
            from: persistedRoutes
        )
    )
}

func cmuxHasAuthorizedTailscaleRoute(
    in routes: [CmxAttachRoute],
    macDeviceID: String,
    legacyRoutes: [CmxAttachRoute],
    userRoutes: [CmxAttachRoute]
) -> Bool {
    let legacyAuthorizations = cmuxLegacyTailscaleAuthorizationSet(
        macDeviceID: macDeviceID,
        from: legacyRoutes
    )
    let userAuthorizations = cmuxUserTailscalePairingAuthorizationsSet(
        from: userRoutes
    )
    return routes.contains { route in
        cmuxLegacyTailscaleAuthorizationEvidence(
            for: route,
            macDeviceID: macDeviceID,
            persistedAuthorizations: legacyAuthorizations
        ) != nil
            || cmuxUserTailscalePairingAuthorization(
                for: route,
                authorizations: userAuthorizations
            ) != nil
    }
}

func cmuxStoredMacTicket(
    name: String,
    routes: [CmxAttachRoute],
    pairedMacDeviceID: String
) throws -> CmxAttachTicket {
    try CmxAttachTicket(
        // An empty id deliberately requests the Mac-wide workspace list. A
        // synthetic non-UUID id would be treated as a scoped workspace and
        // could select the wrong workspace on a multi-workspace Mac.
        workspaceID: "",
        terminalID: nil,
        macDeviceID: pairedMacDeviceID,
        macDisplayName: name,
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: routes
    )
}
