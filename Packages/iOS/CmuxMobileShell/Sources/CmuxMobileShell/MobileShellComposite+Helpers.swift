internal import CMUXMobileCore
internal import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    static func normalizedPairingURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CmxPairingURLScheme.hasPairingScheme(trimmed) else {
            return trimmed
        }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func diagnosticSurfaceHandle(_ surfaceID: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in surfaceID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    static func workspaceActionCapabilities(
        from supportedHostCapabilities: Set<String>,
        allowsMacScopedMutations: Bool
    ) -> MobileWorkspaceActionCapabilities {
        MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: supportedHostCapabilities.contains("workspace.actions.v1"),
            supportsReadStateActions: supportedHostCapabilities.contains("workspace.read_state.v1"),
            supportsCloseActions: supportedHostCapabilities.contains("workspace.close.v1"),
            supportsMoveActions: supportedHostCapabilities.contains("workspace.move.v1") && allowsMacScopedMutations,
            supportsGroupActions: supportedHostCapabilities.contains("workspace.group_actions.v1") && allowsMacScopedMutations
        )
    }

    static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

    /// `true` on a physical iPhone/iPad; `false` in the simulator and in
    /// macOS-hosted package tests. Drives the loopback-pairing rejection:
    /// the simulator's 127.0.0.1 is the host Mac and dev auto-pair depends
    /// on it, while a physical device dialing loopback only ever reaches
    /// itself.
    static var isPhysicalDevice: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// The first reachable host/port route to a Mac, in priority order.
    ///
    /// When `preferNonLoopback` is set (physical devices), a real route
    /// (`.tailscale` etc.) is always chosen over a `.debugLoopback` route even
    /// if the loopback route has a lower (more-preferred) priority, because a
    /// loopback route can never reach a remote Mac from a physical phone. A
    /// loopback route is used only when it is the sole supported route - the
    /// on-device XCUITest mock host, which serves a real listener on `127.0.0.1`
    /// inside the test runner. This is what lets a restored Mac (whose published
    /// routes include both `debug_loopback` and `tailscale`) actually connect
    /// over Tailscale instead of dialing the phone's own loopback and failing.
    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> (String, Int)? {
        let supportedKinds = Set(supportedKinds)
        let ordered = routes.sorted(by: Self.routeSortsBefore)
        func firstHostPort(where predicate: (CmxAttachRoute) -> Bool) -> (String, Int)? {
            for route in ordered {
                if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                    continue
                }
                guard predicate(route), case let .hostPort(host, port) = route.endpoint else {
                    continue
                }
                return (host, port)
            }
            return nil
        }
        if preferNonLoopback {
            // Among non-loopback routes, prefer one whose host is a numeric IP: a
            // raw tailscale/LAN IP is dialable without DNS, whereas a MagicDNS
            // hostname (e.g. "<node>.<tailnet>.ts.net") depends on the client
            // having tailscale DNS active and resolving it. On devices where
            // MagicDNS isn't resolving, dialing the hostname times out and the Mac
            // silently drops out of the list, even though its IP route is fine.
            if let ip = firstHostPort(where: { route in
                guard route.kind != .debugLoopback,
                      case let .hostPort(host, _) = route.endpoint else { return false }
                return Self.isIPLiteralHost(host)
            }) {
                return ip
            }
            if let real = firstHostPort(where: { $0.kind != .debugLoopback }) {
                return real
            }
        }
        return firstHostPort(where: { _ in true })
    }

    /// The first reachable stored route to a Mac for auto-reconnect, as a full
    /// ``CmxAttachRoute``. Host/port routes keep the exact
    /// ``firstReconnectHostPortRoute`` preference order (unchanged behavior for
    /// Tailscale Macs); when a Mac has NO dialable host/port route, this falls
    /// back to its first supported Stack-auth-trusted peer route (iroh).
    ///
    /// The fallback is what makes cmuxRelay Macs auto-connect at all: in that
    /// mode the Mac publishes ONLY an iroh peer route (no host/port), so the
    /// host/port-only selection returned nil, no candidate was dialed, and the
    /// phone sat disconnected until the user re-paired. The stored iroh route
    /// came from a real prior pairing (same trust model as a stored Tailscale
    /// host/port), and its EndpointId is Keychain-stable on the Mac, so it
    /// stays dialable across Mac relaunches.
    static func firstReconnectRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> CmxAttachRoute? {
        let supported = Set(supportedKinds)
        let ordered = routes.sorted(by: Self.routeSortsBefore)
        if let (host, port) = firstReconnectHostPortRoute(
            routes, supportedKinds: supportedKinds, preferNonLoopback: preferNonLoopback
        ) {
            // Return the actual stored route (kind/priority intact), matched by
            // the chosen endpoint.
            return ordered.first { route in
                guard supported.isEmpty || supported.contains(route.kind) else { return false }
                guard case let .hostPort(routeHost, routePort) = route.endpoint else { return false }
                return routeHost == host && routePort == port
            }
        }
        return ordered.first { route in
            guard supported.isEmpty || supported.contains(route.kind) else { return false }
            guard case .peer = route.endpoint else { return false }
            // Peer dials carry the Stack token for the re-mint, so only
            // policy-trusted (encrypted) peer routes qualify.
            return MobileShellRouteAuthPolicy.routeAllowsStackAuth(route)
        }
    }

    /// Ordered dial candidates for one stored Mac: the host/port pick first
    /// (exact ``firstReconnectHostPortRoute`` behavior), then the trusted peer
    /// (iroh) pick when it is a DIFFERENT route. The reconnect loop tries them
    /// in order, so a stale host/port route (a Mac that moved to the iroh-only
    /// cmuxRelay lane while its stored/registry host/port lagged) fails fast and
    /// the stored iroh route still connects - instead of the whole Mac being
    /// skipped after one dead dial.
    static func reconnectRouteCandidates(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [CmxAttachRoute] {
        let supported = Set(supportedKinds)
        let ordered = routes.sorted(by: Self.routeSortsBefore)
        var candidates: [CmxAttachRoute] = []
        if let (host, port) = firstReconnectHostPortRoute(
            routes, supportedKinds: supportedKinds, preferNonLoopback: preferNonLoopback
        ), let hostPortPick = ordered.first(where: { route in
            guard supported.isEmpty || supported.contains(route.kind) else { return false }
            guard case let .hostPort(routeHost, routePort) = route.endpoint else { return false }
            return routeHost == host && routePort == port
        }) {
            candidates.append(hostPortPick)
        }
        if let peerPick = ordered.first(where: { route in
            guard supported.isEmpty || supported.contains(route.kind) else { return false }
            guard case .peer = route.endpoint else { return false }
            return MobileShellRouteAuthPolicy.routeAllowsStackAuth(route)
        }) {
            candidates.append(peerPick)
        }
        return candidates
    }
}
