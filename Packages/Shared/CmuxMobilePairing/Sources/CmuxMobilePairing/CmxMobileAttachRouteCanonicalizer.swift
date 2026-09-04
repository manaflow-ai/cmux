import CMUXMobileCore

/// Rebuilds route IDs and endpoints for compact pairing grammars.
struct CmxMobileAttachRouteCanonicalizer: Sendable {
    func canonicalRoutes(
        from routes: [CmxAttachRoute],
        kind: CmxAttachTransportKind,
        firstPriority: Int,
        priorityStep: Int
    ) throws -> [CmxAttachRoute] {
        try routes
            .filter { $0.kind == kind && !CmxLoopbackHost().matches($0) }
            .enumerated()
            .map { index, route in
                guard case let .hostPort(host, port) = route.endpoint else {
                    throw CmxMobileAttachRoutePlanningError.invalidRoute
                }
                do {
                    return try CmxAttachRoute(
                        id: index == 0
                            ? kind.rawValue
                            : "\(kind.rawValue)_\(index + 1)",
                        kind: kind,
                        endpoint: .hostPort(host: host, port: port),
                        priority: firstPriority + index * priorityStep
                    )
                } catch {
                    throw CmxMobileAttachRoutePlanningError.invalidRoute
                }
            }
    }

    func identityOnlyIrohRoutes(
        from routes: [CmxAttachRoute]
    ) throws -> [CmxAttachRoute] {
        try routes.compactMap { route in
            guard route.kind == .iroh,
                  case let .peer(identity, _) = route.endpoint else {
                return nil
            }
            do {
                return try CmxAttachRoute(
                    id: route.id,
                    kind: .iroh,
                    endpoint: .peer(identity: identity, pathHints: []),
                    priority: route.priority
                )
            } catch {
                throw CmxMobileAttachRoutePlanningError.invalidRoute
            }
        }
    }
}
