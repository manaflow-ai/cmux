import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import os

private let reconnectRouteLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobileReconnectRoutes"
)

enum ReconnectRouteRefreshOutcome: Sendable {
    case refreshedRoutes([CmxAttachRoute])
    case confirmedMissingIroh
    case inconclusive
}

struct ReconnectRefreshSnapshot: Sendable {
    private struct Authority: Hashable, Sendable {
        let deviceID: String
        let instanceTag: String?

        init(deviceID: String, instanceTag: String?) {
            self.deviceID = deviceID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            self.instanceTag = MobileMacInstanceTagAuthority.normalized(instanceTag)
        }
    }

    private let pairedMacsByAuthority: [Authority: [MobilePairedMac]]
    private let registryRoutes: DeviceRegistryRouteIndex?

    init(pairedMacs: [MobilePairedMac], registryDevices: [RegistryDevice]?) {
        pairedMacsByAuthority = Dictionary(grouping: pairedMacs) {
            Authority(deviceID: $0.macDeviceID, instanceTag: $0.instanceTag)
        }
        registryRoutes = registryDevices.map(DeviceRegistryRouteIndex.init(devices:))
    }

    func currentMac(for captured: MobilePairedMac) -> MobilePairedMac? {
        let matches = pairedMacsByAuthority[
            Authority(deviceID: captured.macDeviceID, instanceTag: captured.instanceTag)
        ] ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    func registryResolution(for captured: MobilePairedMac) -> DeviceRegistryRouteResolution? {
        registryRoutes?.resolve(
            macDeviceID: captured.macDeviceID,
            instanceTag: captured.instanceTag
        )
    }
}

@MainActor
extension MobileShellComposite {
    /// Resolves one immutable pre-Iroh capability for an exact raw Tailscale
    /// route. Fresh registry/manual routes cannot create this evidence; they
    /// must match a route retained by the local schema migration.
    static func legacyTailscaleAuthorizationEvidence(
        for route: CmxAttachRoute,
        macDeviceID: String,
        persistedRoutes: [CmxAttachRoute]
    ) -> CmxLegacyTailscaleAuthorizationEvidence? {
        guard route.kind == .tailscale,
              case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        for persistedRoute in persistedRoutes where persistedRoute.kind == .tailscale {
            guard case let .hostPort(persistedHost, persistedPort) = persistedRoute.endpoint,
                  let evidence = try? CmxLegacyTailscaleAuthorizationEvidence(
                      macDeviceID: macDeviceID,
                      host: persistedHost,
                      port: persistedPort
                  ),
                  evidence.authorizes(
                      macDeviceID: macDeviceID,
                      host: host,
                      port: port
                  ) else {
                continue
            }
            return evidence
        }
        return nil
    }

    /// Supported routes for reconnecting an already-paired Mac.
    ///
    /// Unlike the legacy host/port helper, this preserves Iroh peer routes. Once
    /// a supported Iroh route exists, it also pins the pairing to Iroh and drops
    /// every raw host/port fallback. A numeric Tailscale route is first copied
    /// into the pinned Iroh route as a private fallback address, so Tailscale can
    /// still carry Iroh without receiving a Stack bearer. Otherwise an admission
    /// or revocation failure could silently downgrade around the Iroh device
    /// grant. Pairings without an authenticated Iroh identity remain fail-closed.
    static func storedReconnectRoutes(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [CmxAttachRoute] {
        let supportedKinds = Set(supportedKinds)
        var ordered = CmxAttachRoute.addingIrohPrivatePaths(
            to: routes,
            observedAt: Date()
        )
            .filter { supportedKinds.isEmpty || supportedKinds.contains($0.kind) }
            .sorted(by: Self.routeSortsBefore)
        if preferNonLoopback {
            ordered.removeAll { $0.kind == .debugLoopback }
        }
        let irohRoutes = ordered.filter { $0.kind == .iroh }
        if !irohRoutes.isEmpty {
            return irohRoutes
        }
        return ordered
    }

    /// Refresh the active row only while its account, device, and authenticated
    /// instance authority still match the values captured before the network call.
    func refreshRoutesFromRegistry(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) {
        guard let deviceRegistry, let pairedMacStore else { return }
        let macDeviceID = mac.macDeviceID
        let localRoutes = mac.routes
        let displayName = mac.displayName
        let capturedInstanceTag = mac.instanceTag
        let task = Task { [weak self] in
            let registryRoutes = await deviceRegistry.freshRoutes(
                forMacDeviceID: macDeviceID,
                instanceTag: capturedInstanceTag
            )
            guard let updated = DeviceRegistryService.selectReconnectRoutes(
                local: localRoutes,
                registry: registryRoutes
            ), let self else { return }
            await self.performSerializedPairedMacWrite(ifStillCurrent: nil) {
                guard await self.isScopeCurrent(scope),
                      await !self.isForgottenMacDeviceID(
                        macDeviceID,
                        instanceTag: capturedInstanceTag,
                        scope: scope
                      ) else { return }
                let activeMac: MobilePairedMac?
                do {
                    activeMac = try await pairedMacStore.activeMac(
                        stackUserID: scope.userID,
                        teamID: scope.teamID
                    )
                } catch {
                    reconnectRouteLog.debug("registry refresh recheck failed: \(String(describing: error), privacy: .public)")
                    return
                }
                guard await self.isScopeCurrent(scope),
                      await !self.isForgottenMacDeviceID(
                        macDeviceID,
                        instanceTag: capturedInstanceTag,
                        scope: scope
                      ),
                      DeviceRegistryService.shouldApplyRegistryRefresh(
                        isSignedIn: self.isSignedIn,
                        capturedUserID: scope.userID,
                        currentUserID: self.identityProvider?.currentUserID ?? scope.userID,
                        activeMacID: activeMac?.macDeviceID,
                        activeMacInstanceTag: activeMac?.instanceTag,
                        targetMacID: macDeviceID,
                        targetInstanceTag: capturedInstanceTag
                ) else { return }
                do {
                    let wrote = try await pairedMacStore.upsertRoutesIfAuthorized(
                        macDeviceID: macDeviceID,
                        displayName: displayName,
                        routes: updated,
                        condition: .matchingInstanceTag(capturedInstanceTag),
                        markActive: nil,
                        stackUserID: scope.userID,
                        teamID: scope.teamID,
                        now: Date()
                    )
                    guard wrote else { return }
                } catch {
                    reconnectRouteLog.debug("registry refresh upsert failed: \(String(describing: error), privacy: .public)")
                    return
                }
                if await self.isForgottenMacDeviceID(
                    macDeviceID,
                    instanceTag: capturedInstanceTag,
                    scope: scope
                ) {
                    try? await pairedMacStore.remove(
                        macDeviceID: macDeviceID,
                        instanceTag: capturedInstanceTag,
                        stackUserID: scope.userID,
                        teamID: scope.teamID
                    )
                    return
                }
                if await self.isScopeCurrent(scope) { await self.loadPairedMacs() }
            }
        }
        registryRouteRefreshTask = task
    }

    /// The first reachable host/port route to a Mac, in priority order.
    ///
    /// When `preferNonLoopback` is set (physical devices), a real route
    /// (`.tailscale` etc.) is always chosen over a `.debugLoopback` route even
    /// if the loopback route has a lower (more-preferred) priority, because a
    /// loopback route can never reach a remote Mac from a physical phone. A
    /// loopback route is used only when it is the sole supported route — the
    /// on-device XCUITest mock host, which serves a real listener on `127.0.0.1`
    /// inside the test runner.
    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> (String, Int)? {
        reconnectHostPortRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ).first.map { ($0.host, $0.port) }
    }

    /// Resume foreground-only refresh loops after the app becomes active.
    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        // Covers stores constructed already-signed-in (no isSignedIn edge) and
        // restarts a subscription torn down while backgrounded.
        evaluatePresenceSubscription()
        let shouldResync = shouldResyncTerminalOutputOnForeground()
        lastBackgroundedAt = nil
        // Persisted connections let the recovery owner probe first. Restarting
        // their listener here can make a dead MobileCoreRPCClient reopen its old
        // transport before the probe decides to replace it, creating two owners
        // for one foreground transition. Preview/legacy clients have no stored
        // route to redial, so retain their same-client resubscribe fallback.
        if shouldResync, pairedMacStore == nil {
            resyncTerminalOutput(reason: "foreground", restartEventStream: true)
        }
        recoverForegroundConnectionIfNeeded(resyncAfterHealthy: shouldResync)
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
        guard lastBackgroundedAt == nil else { return }
        lastBackgroundedAt = runtime?.now() ?? Date()
    }

    func loadReconnectRefreshSnapshot(
        scope: MobileShellScopeSnapshot
    ) async -> ReconnectRefreshSnapshot? {
        guard await isScopeCurrent(scope) else { return nil }
        let registryDevices: [RegistryDevice]?
        if let deviceRegistry {
            switch await deviceRegistry.listDevices() {
            case .ok(let devices):
                registryDevices = devices
            case .authRejected, .transientFailure:
                registryDevices = nil
            }
        } else {
            registryDevices = nil
        }
        guard await isScopeCurrent(scope),
              let pairedMacStore,
              let pairedMacs = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ),
              await isScopeCurrent(scope) else {
            return nil
        }
        return ReconnectRefreshSnapshot(
            pairedMacs: pairedMacs,
            registryDevices: registryDevices
        )
    }

    /// Re-read one exact account/device/instance row immediately before
    /// presenting legacy-Mac migration guidance. A registry snapshot can become
    /// stale while Presence persists an Iroh route, so only the current paired
    /// store may authorize that user-facing conclusion.
    func isCurrentLegacyPrivateNetworkPairing(
        _ captured: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard await isScopeCurrent(scope),
              let pairedMacStore,
              let pairedMacs = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ),
              await isScopeCurrent(scope),
              let currentMac = ReconnectRefreshSnapshot(
                  pairedMacs: pairedMacs,
                  registryDevices: nil
              ).currentMac(for: captured),
              await !isForgottenMacDeviceID(
                  captured.macDeviceID,
                  instanceTag: captured.instanceTag,
                  scope: scope
              ) else {
            return false
        }
        return currentMac.routes.contains { $0.kind == .tailscale }
            && !currentMac.routes.contains { $0.kind == .iroh }
    }

    func freshReconnectRoutesAfterLocalFailure(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot,
        snapshot: ReconnectRefreshSnapshot?
    ) async -> ReconnectRouteRefreshOutcome {
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let snapshot,
              await isScopeCurrent(scope),
              await !isForgottenMacDeviceID(
                  mac.macDeviceID,
                  instanceTag: mac.instanceTag,
                  scope: scope
              ),
              let currentMac = snapshot.currentMac(for: mac),
              await isScopeCurrent(scope),
              await !isForgottenMacDeviceID(
                  mac.macDeviceID,
                  instanceTag: mac.instanceTag,
                  scope: scope
              ) else {
            return .inconclusive
        }
        let localRoutes = Self.storedReconnectRoutes(
            currentMac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        let requiresIroh = localRoutes.contains { $0.kind == .iroh }
            || mac.routes.contains { $0.kind == .iroh }
        // Presence may authorize and persist the same registry routes while the
        // list request is in flight. That current row is newer than the captured
        // candidate and is already scoped to this account/device/instance, so use
        // it directly instead of mistaking registry equality for "no route."
        if currentMac.routes != mac.routes {
            let reconnectRoutes = Self.storedReconnectRoutes(
                currentMac.routes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
            if !reconnectRoutes.isEmpty,
               reconnectRoutes.contains(where: {
                   $0.kind == .iroh || $0.kind == .debugLoopback
               }) {
                return .refreshedRoutes(reconnectRoutes)
            }
        }

        guard case .unique(let registryRoutes) = snapshot.registryResolution(for: mac) else {
            return .inconclusive
        }
        let registryHasIroh = registryRoutes.contains { $0.kind == .iroh }
        let isLegacyPrivateNetworkPairing = !mac.routes.contains { $0.kind == .iroh }
            && mac.routes.contains { $0.kind == .tailscale }
        guard let updatedRoutes = DeviceRegistryService.selectReconnectRoutes(
            local: currentMac.routes,
            registry: registryRoutes
        ) else {
            return isLegacyPrivateNetworkPairing && !registryHasIroh
                ? .confirmedMissingIroh
                : .inconclusive
        }
        let reconnectRoutes = Self.storedReconnectRoutes(
            updatedRoutes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        // Once this pairing has used Iroh, a cloud refresh that omits Iroh is
        // stale or downgraded input. Keep the local Iroh capability pin instead
        // of converting a grant failure into raw private-network RPC.
        guard !requiresIroh || reconnectRoutes.contains(where: { $0.kind == .iroh }) else {
            return .inconclusive
        }
        if !reconnectRoutes.isEmpty,
           reconnectRoutes.contains(where: { $0.kind == .iroh || $0.kind == .debugLoopback }) {
            return .refreshedRoutes(reconnectRoutes)
        }
        return isLegacyPrivateNetworkPairing && !registryHasIroh
            ? .confirmedMissingIroh
            : .inconclusive
    }

    func shouldResyncTerminalOutputOnForeground() -> Bool {
        guard connectionState == .connected,
              remoteClient != nil,
              terminalEventListenerTask != nil,
              let lastBackgroundedAt else {
            return true
        }
        let now = runtime?.now() ?? Date()
        guard now.timeIntervalSince(lastBackgroundedAt) < Self.foregroundResyncShortBackgroundThreshold else {
            return true
        }
        let last = lastTerminalEventAt ?? now
        return now.timeIntervalSince(last) >= Self.renderGridLivenessSilenceThreshold
    }

    /// Writes the persisted paired-Mac hint only when `generation` is current.
    func setHasKnownPairedMac(_ value: Bool, generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        hasKnownPairedMac = value
    }

    /// Mark the stored-Mac reconnect attempt resolved only for the current generation.
    func finishStoredMacReconnectAttempt(generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
    }

    /// Returns the completed result when an async stored reconnect must stop.
    /// A newer generation owns the work (`false`); an already-live foreground
    /// client satisfies the request without another dial (`true`).
    func storedMacReconnectInterruptionResult(generation: Int) -> Bool? {
        guard generation == storedMacReconnectGeneration else { return false }
        guard !hasActiveMacConnection else {
            finishStoredMacReconnectAttempt(generation: generation)
            return true
        }
        return nil
    }

    /// Ordered host/port reconnect candidates for a Mac, preserving the single-route
    /// preference policy but keeping fallbacks available for the same Mac.
    ///
    /// With `preferNonLoopback` (real physical devices) the list never contains
    /// a `.debugLoopback` route. Callers iterate every candidate, so keeping
    /// loopback as either a tail fallback or the sole route would dial the
    /// phone's own `127.0.0.1`, never the saved Mac. Explicit mock/simulator
    /// harnesses pass `false` and retain loopback for their in-process host.
    static func reconnectHostPortRoutes(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [(host: String, port: Int, routeID: String)] {
        let supportedKinds = Set(supportedKinds)
        let hasSupportedIrohRoute = routes.contains { route in
            route.kind == .iroh
                && (supportedKinds.isEmpty || supportedKinds.contains(.iroh))
        }
        guard !hasSupportedIrohRoute else {
            return []
        }
        let ordered = routes.sorted(by: Self.routeSortsBefore)
        var seenEndpoints = Set<String>()

        func appendCandidates(
            where predicate: (CmxAttachRoute) -> Bool,
            to candidates: inout [(host: String, port: Int, routeID: String)]
        ) {
            for route in ordered {
                if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                    continue
                }
                guard predicate(route),
                      case let .hostPort(host, port) = route.endpoint else {
                    continue
                }
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
                return Self.isIPLiteralHost(host)
            }, to: &candidates)
            appendCandidates(where: { $0.kind != .debugLoopback }, to: &candidates)
            return candidates
        }
        appendCandidates(where: { _ in true }, to: &candidates)
        return candidates
    }

    /// Merges a constrained reconnect ticket with the previously persisted route set.
    ///
    /// Constrained tickets prove only the dialed endpoint, not that other stored
    /// endpoints disappeared. Prefer the freshly connected route when an id or
    /// endpoint collides, coalesce usable hints for one Iroh peer, then keep the
    /// remaining stored fallbacks.
    static func mergedReconnectRoutes(
        ticketRoutes: [CmxAttachRoute],
        storedRoutes: [CmxAttachRoute],
        at now: Date = Date()
    ) -> [CmxAttachRoute] {
        var merged: [CmxAttachRoute] = []
        var seenIDs = Set<String>()
        var seenEndpoints = Set<String>()
        var peerRouteIndex: [CmxIrohPeerIdentity: Int] = [:]

        func hintKey(_ hint: CmxIrohPathHint) -> String {
            let profileKey = hint.networkProfile.map {
                "\($0.source.rawValue):\($0.profileID)"
            } ?? ""
            return [
                hint.kind.rawValue,
                hint.value,
                hint.source.rawValue,
                hint.privacyScope.rawValue,
                profileKey,
            ].map { "\($0.utf8.count):\($0)" }.joined()
        }

        func coalescingPeerHints(
            into existing: CmxAttachRoute,
            from incoming: CmxAttachRoute
        ) -> CmxAttachRoute {
            guard case let .peer(identity, existingHints) = existing.endpoint,
                  case let .peer(_, incomingHints) = incoming.endpoint else {
                return existing
            }
            var seenHints = Set<String>()
            // A constrained ticket is not a complete discovery snapshot. Keep
            // other hints that remain safe and unexpired as bounded fallbacks.
            let combinedHints = (existingHints + incomingHints).filter {
                seenHints.insert(hintKey($0)).inserted
            }
            let boundedHints = Array(
                combinedHints.prefix(CmxAttachEndpoint.maximumIrohPathHintCount)
            )
            return (try? CmxAttachRoute(
                id: existing.id,
                kind: existing.kind,
                endpoint: .peer(identity: identity, pathHints: boundedHints),
                priority: existing.priority
            )) ?? existing
        }

        func append(_ rawRoute: CmxAttachRoute) {
            guard let route = rawRoute.disclosed(for: .authenticated, at: now) else {
                return
            }
            if case let .peer(identity, _) = route.endpoint {
                if let index = peerRouteIndex[identity] {
                    // Stable Iroh route ids may collide before the stored route
                    // contributes still-usable hints for the same peer.
                    seenIDs.insert(route.id)
                    merged[index] = coalescingPeerHints(into: merged[index], from: route)
                } else {
                    guard seenIDs.insert(route.id).inserted else {
                        return
                    }
                    peerRouteIndex[identity] = merged.count
                    merged.append(route)
                }
                return
            }
            guard seenIDs.insert(route.id).inserted else {
                return
            }
            let key: String
            switch route.endpoint {
            case let .hostPort(host, port):
                key = "host:\(host)\u{1F}\(port)"
            case let .url(url):
                key = "url:\(url)"
            case .peer:
                return
            }
            guard seenEndpoints.insert(key).inserted else { return }
            merged.append(route)
        }

        ticketRoutes.forEach(append)
        storedRoutes.forEach(append)
        return merged.sorted(by: Self.routeSortsBefore)
    }
}
