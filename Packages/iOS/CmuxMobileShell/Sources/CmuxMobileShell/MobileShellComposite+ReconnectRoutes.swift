import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import os

private let reconnectRouteLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobileReconnectRoutes"
)

@MainActor
extension MobileShellComposite {
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
                      await !self.isForgottenMacDeviceID(macDeviceID, scope: scope) else { return }
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
                      await !self.isForgottenMacDeviceID(macDeviceID, scope: scope),
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
                if await self.isForgottenMacDeviceID(macDeviceID, scope: scope) {
                    try? await pairedMacStore.remove(
                        macDeviceID: macDeviceID,
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
        if shouldResync {
            resyncTerminalOutput(reason: "foreground", restartEventStream: true)
        }
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
        let refreshed = Self.reconnectHostPortRoutes(
            updatedRoutes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard !refreshed.isEmpty else { return nil }
        let tried = Set(triedRoutes.map { "\($0.host)\u{1F}\($0.port)" })
        let fresh = Set(refreshed.map { "\($0.host)\u{1F}\($0.port)" })
        guard fresh != tried else { return nil }
        return refreshed
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

    /// Ordered host/port reconnect candidates for a Mac, preserving the single-route
    /// preference policy but keeping fallbacks available for the same Mac.
    ///
    /// With `preferNonLoopback` (physical devices) the list NEVER contains a
    /// `.debugLoopback` route while any real candidate exists — not even as a
    /// trailing fallback. Callers iterate every candidate, so a loopback tail
    /// entry would get dialed once the real routes fail; on a phone that
    /// reaches whatever local process is listening on 127.0.0.1, and the
    /// manual attach-ticket path treats loopback as trusted. Loopback stays
    /// reachable only as the sole supported route (the on-device XCUITest
    /// mock host).
    static func reconnectHostPortRoutes(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [(host: String, port: Int, routeID: String)] {
        let supportedKinds = Set(supportedKinds)
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
            // Any real candidate found: stop here so loopback is unreachable
            // even as a dial-everything fallback (see the doc comment).
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
    static func mergedReconnectRoutes(
        ticketRoutes: [CmxAttachRoute],
        storedRoutes: [CmxAttachRoute]
    ) -> [CmxAttachRoute] {
        var merged: [CmxAttachRoute] = []
        var seenIDs = Set<String>()
        var seenEndpoints = Set<String>()

        func endpointKey(_ route: CmxAttachRoute) -> String {
            switch route.endpoint {
            case let .hostPort(host, port):
                return "host:\(host)\u{1F}\(port)"
            case let .peer(id, _, directAddrs, relayURL):
                return "peer:\(id)\u{1F}\(directAddrs.joined(separator: ","))\u{1F}\(relayURL ?? "")"
            case let .url(url):
                return "url:\(url)"
            }
        }

        func append(_ route: CmxAttachRoute) {
            let key = endpointKey(route)
            guard seenIDs.insert(route.id).inserted,
                  seenEndpoints.insert(key).inserted else {
                return
            }
            merged.append(route)
        }

        ticketRoutes.forEach(append)
        storedRoutes.forEach(append)
        return merged.sorted(by: Self.routeSortsBefore)
    }
}
