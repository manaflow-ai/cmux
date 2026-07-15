import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    var hasStoredMacReconnectDemand: Bool {
        connectionLifecycle.hasStoredMacReconnectDemand
            || connectionLifecycleReconnectPendingAfterRetirement
            || connectionLifecycleTaskOwnership.retiredCarriesReconnectDemand
    }

    /// Yield automatic recovery ownership before the user enters manual pairing.
    public func prepareForManualPairing() {
        supersedeAutomaticReconnectOwnership(clearPairingState: true)
    }

    /// Resume foreground-only refresh loops after the app becomes active.
    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        // Covers stores constructed already-signed-in (no isSignedIn edge) and
        // restarts a subscription torn down while backgrounded.
        evaluatePresenceSubscription()
        let now = runtime?.now() ?? Date()
        let effect = connectionLifecycle.becameActive(
            at: now,
            shortDwellThreshold: Self.foregroundResyncShortBackgroundThreshold,
            health: connectionLifecycleHealth(at: now),
            reconnectStackUserID: identityProvider?.currentUserID
        )
        applyConnectionLifecycleEffect(effect)
        // The foreground Mac's workspace list updates live over the sync stream,
        // but the other Macs are a read-only snapshot. Re-aggregate them on
        // foreground so workspaces created on another Mac while backgrounded
        // appear without a manual pull-to-refresh.
        if multiMacAggregationEnabled, connectionState == .connected {
            self.scheduleSecondaryAggregation()
        }
    }

    /// Record that the app left the active scene phase.
    public func suspendForegroundRefresh() {
        connectionLifecycle.becameInactive(at: runtime?.now() ?? Date())
    }

    /// Coalesces direct launch/auth callers onto the same reconnect episode as network and presence.
    @discardableResult
    public func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool {
        guard remoteClient != nil || pairedMacStore != nil else {
            let recoveryWasFailed = connectionLifecycle.recoveryFailed
            connectionLifecycle.completeUnavailableStoredMacReconnect()
            captureConnectionRecoveryFailureIfNeeded(wasFailed: recoveryWasFailed)
            return connectionState == .connected
        }
        let request = connectionLifecycle.requestStoredMacReconnect(
            stackUserID: stackUserID,
            health: connectionLifecycleHealth(at: runtime?.now() ?? Date())
        )
        await withCheckedContinuation { continuation in
            connectionLifecycleRequestWaiters[request.id] = continuation
            applyConnectionLifecycleEffect(request.effect)
        }
        return connectionState == .connected
    }

    func freshReconnectRoutesAfterLocalFailure(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot,
        triedRoutes: [(host: String, port: Int, routeID: String)]
    ) async -> [(host: String, port: Int, routeID: String)]? {
        guard let deviceRegistry,
              await isScopeCurrent(scope),
              await !isForgottenMacDeviceID(mac.macDeviceID, scope: scope),
              let registryRoutes = await deviceRegistry.freshRoutes(
                  forMacDeviceID: mac.macDeviceID,
                  instanceTag: mac.instanceTag
              ),
              connectionState != .connected,
              let pairedMacStore,
              let currentMac = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ).first(where: { $0.macDeviceID == mac.macDeviceID }),
              currentMac.instanceTag == mac.instanceTag,
              let updatedRoutes = DeviceRegistryService.selectReconnectRoutes(
                local: mac.routes,
                registry: registryRoutes
              ) else {
            return nil
        }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let refreshed = updatedRoutes.reconnectHostPortRoutes(
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard !refreshed.isEmpty else { return nil }
        let tried = Set(triedRoutes.map { "\($0.host)\u{1F}\($0.port)" })
        let fresh = Set(refreshed.map { "\($0.host)\u{1F}\($0.port)" })
        guard fresh != tried else { return nil }
        return refreshed
    }

    /// Writes the persisted paired-Mac hint only when `generation` is current.
    func setHasKnownPairedMac(_ value: Bool, generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        hasKnownPairedMac = value
    }

}

extension Array where Element == CmxAttachRoute {
    /// The first reachable host/port route to a Mac, in priority order.
    ///
    /// When `preferNonLoopback` is set (physical devices), a real route
    /// (`.tailscale` etc.) is always chosen over a `.debugLoopback` route even
    /// if the loopback route has a lower (more-preferred) priority, because a
    /// loopback route can never reach a remote Mac from a physical phone. A
    /// loopback route is used only when it is the sole supported route (the
    /// on-device XCUITest mock host, which serves a real listener on `127.0.0.1`
    /// inside the test runner).
    func firstReconnectHostPortRoute(
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> (String, Int)? {
        reconnectHostPortRoutes(
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ).first.map { ($0.host, $0.port) }
    }

    /// Ordered host/port reconnect candidates for a Mac, preserving the single-route
    /// preference policy but keeping fallbacks available for the same Mac.
    ///
    /// With `preferNonLoopback` (physical devices) the list NEVER contains a
    /// `.debugLoopback` route while any real candidate exists, not even as a
    /// trailing fallback. Callers iterate every candidate, so a loopback tail
    /// entry would get dialed once the real routes fail; on a phone that
    /// reaches whatever local process is listening on 127.0.0.1, and the
    /// manual attach-ticket path treats loopback as trusted. Loopback stays
    /// reachable only as the sole supported route (the on-device XCUITest
    /// mock host).
    func reconnectHostPortRoutes(
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [(host: String, port: Int, routeID: String)] {
        let supportedKinds = Set(supportedKinds)
        let hasSupportedIrohRoute = contains { route in
            route.kind == .iroh
                && (supportedKinds.isEmpty || supportedKinds.contains(.iroh))
        }
        guard !hasSupportedIrohRoute else { return [] }
        let ordered = sortedByReconnectPriority()
        var seenEndpoints = Set<String>()

        func appendCandidates(
            where predicate: (CmxAttachRoute) -> Bool,
            to candidates: inout [(host: String, port: Int, routeID: String)]
        ) {
            for route in ordered {
                if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) { continue }
                guard predicate(route),
                      case let .hostPort(host, port) = route.endpoint else { continue }
                let endpointKey = "\(host)\u{1F}\(port)"
                guard seenEndpoints.insert(endpointKey).inserted else { continue }
                candidates.append((host: host, port: port, routeID: route.id))
            }
        }

        var candidates: [(host: String, port: Int, routeID: String)] = []
        if preferNonLoopback {
            appendCandidates(where: { route in
                guard route.kind != .debugLoopback,
                      case let .hostPort(host, _) = route.endpoint else { return false }
                return host.cmuxIsIPLiteralHost
            }, to: &candidates)
            appendCandidates(where: { $0.kind != .debugLoopback }, to: &candidates)
            guard candidates.isEmpty else { return candidates }
        }
        appendCandidates(where: { _ in true }, to: &candidates)
        return candidates
    }

    /// Merges a constrained reconnect ticket with the previously persisted route set.
    ///
    /// Constrained tickets prove only the dialed endpoint, not that other stored
    /// endpoints disappeared. Prefer the freshly connected route when an id or
    /// endpoint collides, then keep the remaining stored fallbacks.
    func mergedWithStoredReconnectRoutes(_ storedRoutes: [CmxAttachRoute]) -> [CmxAttachRoute] {
        var merged: [CmxAttachRoute] = []
        var seenIDs = Set<String>()
        var seenEndpoints = Set<String>()

        func append(_ route: CmxAttachRoute) {
            let key = route.reconnectEndpointKey
            guard seenIDs.insert(route.id).inserted,
                  seenEndpoints.insert(key).inserted else {
                return
            }
            merged.append(route)
        }

        forEach(append)
        storedRoutes.forEach(append)
        return merged.sortedByReconnectPriority()
    }

    /// Supported routes for reconnecting an already-paired Mac.
    ///
    /// Unlike the legacy host/port helper, this preserves Iroh peer routes. Once
    /// a supported Iroh route exists, it also pins the pairing to Iroh and drops
    /// every raw host/port fallback. Otherwise an admission or revocation failure
    /// could silently downgrade to a Stack-bearer Tailscale request and bypass the
    /// Iroh device grant. Legacy Macs that never advertised Iroh keep their raw
    /// private-network routes.
    func storedReconnectRoutes(
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [CmxAttachRoute] {
        let supportedKinds = Set(supportedKinds)
        var ordered = filter { supportedKinds.isEmpty || supportedKinds.contains($0.kind) }
            .sortedByReconnectPriority()
        if preferNonLoopback, ordered.contains(where: { $0.kind != .debugLoopback }) {
            ordered.removeAll { $0.kind == .debugLoopback }
        }
        let irohRoutes = ordered.filter { $0.kind == .iroh }
        return irohRoutes.isEmpty ? ordered : irohRoutes
    }

    private func sortedByReconnectPriority() -> [CmxAttachRoute] {
        sorted {
            if $0.priority == $1.priority {
                return $0.id < $1.id
            }
            return $0.priority < $1.priority
        }
    }
}

private extension CmxAttachRoute {
    var reconnectEndpointKey: String {
        switch endpoint {
        case let .hostPort(host, port):
            return "host:\(host)\u{1F}\(port)"
        case let .peer(id, _, directAddrs, relayURL):
            return "peer:\(id)\u{1F}\(directAddrs.joined(separator: ","))\u{1F}\(relayURL ?? "")"
        case let .url(url):
            return "url:\(url)"
        }
    }
}

private extension String {
    var cmuxIsIPLiteralHost: Bool {
        if contains(":") { return true }
        let octets = split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value), !part.isEmpty else {
                return false
            }
            return String(value) == part
        }
    }
}
