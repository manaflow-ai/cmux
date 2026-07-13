import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    var hasStoredMacReconnectDemand: Bool {
        connectionLifecycle.hasStoredMacReconnectDemand
            || connectionLifecycleReconnectPendingAfterRetirement
    }

    /// Yield automatic recovery ownership before the user enters manual pairing.
    public func prepareForManualPairing() {
        if connectionLifecycle.isRecovering || connectionLifecycle.hasStoredMacReconnectDemand {
            resetConnectionLifecycle()
        }
        connectionLifecycleReconnectPendingAfterRetirement = false
        invalidatePairingAttempt()
        clearPairingError()
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

    func requestConnectionLifecycleRecovery(
        _ trigger: MobileConnectionLifecycleTrigger
    ) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        if trigger == .eventStreamLost {
            scheduleWorkspaceListRefreshFromEvent()
        }
        let effect = connectionLifecycle.request(
            trigger,
            health: connectionLifecycleHealth(at: runtime?.now() ?? Date()),
            reconnectStackUserID: identityProvider?.currentUserID
        )
        applyConnectionLifecycleEffect(effect)
    }

    func resetConnectionLifecycle() {
        let canceledKind = connectionLifecycle.activeEpisode?.kind
        let canceledStreamRepair = canceledKind == .streamRepair
        let canceledOperation = connectionLifecycleTask
        connectionLifecycle.reset()
        resumeCompletedConnectionLifecycleRequests()
        connectionLifecycleReconnectPendingAfterRetirement = false
        invalidateStoredMacReconnectAttempt()
        connectionLifecycleTask = nil
        if canceledKind == .reconnect {
            retireConnectionLifecycleTask(canceledOperation)
        } else {
            canceledOperation?.cancel()
        }
        connectionLifecycleDeadlineTask?.cancel()
        connectionLifecycleDeadlineTask = nil
        reconcileMacConnectionStatusAfterLifecycleReset(
            canceledStreamRepair: canceledStreamRepair
        )
    }

    func restartStoredMacReconnectAfterScopeChange() {
        guard isSignedIn,
              connectionState != .connected,
              pairedMacStore != nil else { return }
        guard connectionLifecycleRetiredTask == nil else {
            connectionLifecycleReconnectPendingAfterRetirement = true
            return
        }
        let request = connectionLifecycle.requestStoredMacReconnect(
            stackUserID: identityProvider?.currentUserID,
            health: connectionLifecycleHealth(at: runtime?.now() ?? Date())
        )
        applyConnectionLifecycleEffect(request.effect)
    }

    func completeStreamRepairLifecycleEpisodeIfNeeded() {
        guard let episode = connectionLifecycle.activeEpisode,
              episode.kind == .streamRepair else { return }
        finishConnectionLifecycleEpisode(id: episode.id)
    }

    func failConnectionLifecycleEpisodeIfNeeded() {
        guard let episode = connectionLifecycle.activeEpisode else { return }
        finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
    }

    private func connectionLifecycleHealth(at now: Date) -> MobileConnectionLifecycleHealthSnapshot {
        let lastEvent = lastTerminalEventAt ?? now
        return MobileConnectionLifecycleHealthSnapshot(
            connected: connectionState == .connected,
            hasClient: remoteClient != nil,
            hasListener: terminalEventListenerTask != nil,
            eventStreamFresh: now.timeIntervalSince(lastEvent) < Self.renderGridLivenessSilenceThreshold,
            canReconnectPersistedMac: pairedMacStore != nil
        )
    }

    private func applyConnectionLifecycleEffect(
        _ effect: MobileConnectionLifecycleEffect?
    ) {
        guard case .start(let episode) = effect else { return }
        if episode.kind == .reconnect, connectionLifecycleRetiredTask != nil {
            // A cancellation-insensitive reconnect still owns the underlying
            // dependency. Coalesce explicit Retry demand for replay after the
            // retired slot drains instead of stacking another task behind the
            // same wedged store or transport.
            if episode.triggers.contains(.manualRetry) {
                connectionLifecycleReconnectPendingAfterRetirement = true
            }
            finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
            return
        }
        connectionLifecycleTask?.cancel()
        connectionLifecycleDeadlineTask?.cancel()
        connectionLifecycleTask = Task { @MainActor [weak self] in
            guard let self, self.connectionLifecycle.ownsEpisode(episode.id) else { return }
            switch episode.kind {
            case .streamRepair:
                guard self.connectionState == .connected,
                      self.remoteClient != nil else {
                    self.finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
                    return
                }
                self.markMacConnectionReconnecting()
                self.resyncTerminalOutput(
                    reason: "lifecycle.\(episode.id)",
                    restartEventStream: true
                )
                if self.multiMacAggregationEnabled {
                    self.scheduleSecondaryAggregation()
                }
                if self.terminalEventListenerTask == nil {
                    if self.runtime?.supportsServerPushEvents ?? true {
                        self.finishConnectionLifecycleEpisode(id: episode.id, succeeded: false)
                    } else {
                        // Replay-only runtimes intentionally have no listener.
                        // Scheduling the replay is their complete repair path.
                        self.markMacConnectionHealthy()
                    }
                }
            case .reconnect:
                let outcome = await self.performStoredMacReconnect(
                    stackUserID: episode.reconnectStackUserID
                )
                guard !Task.isCancelled,
                      self.connectionLifecycle.ownsEpisode(episode.id) else { return }
                self.finishConnectionLifecycleEpisode(
                    id: episode.id,
                    succeeded: outcome != .failed
                )
            }
            if self.connectionLifecycle.ownsEpisode(episode.id), episode.kind == .streamRepair {
                self.connectionLifecycleTask = nil
            }
        }
        if episode.kind == .reconnect {
            let deadline = storedMacReconnectDeadline
            connectionLifecycleDeadlineTask = Task { @MainActor [weak self] in
                await deadline()
                guard !Task.isCancelled else { return }
                self?.expireStoredMacReconnectEpisode(id: episode.id)
            }
        } else {
            connectionLifecycleDeadlineTask = nil
        }
    }

    /// Expires exactly the reconnect episode that armed this deadline. The
    /// episode identity guard makes a late, cancellation-insensitive deadline
    /// harmless after success, sign-out, manual pairing, or replacement.
    private func expireStoredMacReconnectEpisode(id: UInt64) {
        guard connectionLifecycle.ownsEpisode(id),
              connectionLifecycle.activeEpisode?.kind == .reconnect else { return }
        let operation = connectionLifecycleTask
        connectionLifecycleTask = nil
        connectionLifecycleDeadlineTask = nil
        retireConnectionLifecycleTask(operation)
        invalidateStoredMacReconnectAttempt()
        applyStoredMacReconnectDeadlineFailure()
        finishConnectionLifecycleEpisode(id: id, succeeded: false)
    }

    /// Retains at most one cancellation-insensitive reconnect until it actually
    /// exits. Replacement lifecycle episodes fail while this slot is occupied,
    /// which bounds suspended store/transport work across repeated Retry taps.
    private func retireConnectionLifecycleTask(_ operation: Task<Void, Never>?) {
        guard let operation else { return }
        operation.cancel()
        guard connectionLifecycleRetiredTask == nil else { return }
        connectionLifecycleRetiredTaskGeneration &+= 1
        let generation = connectionLifecycleRetiredTaskGeneration
        connectionLifecycleRetiredTask = Task { @MainActor [weak self] in
            await operation.value
            guard let self,
                  self.connectionLifecycleRetiredTaskGeneration == generation else { return }
            self.connectionLifecycleRetiredTask = nil
            let shouldReconnect = self.connectionLifecycleReconnectPendingAfterRetirement
            self.connectionLifecycleReconnectPendingAfterRetirement = false
            if shouldReconnect {
                self.restartStoredMacReconnectAfterScopeChange()
            }
        }
    }

    func finishConnectionLifecycleEpisode(id: UInt64, succeeded: Bool = true) {
        guard connectionLifecycle.ownsEpisode(id) else { return }
        connectionLifecycleDeadlineTask?.cancel()
        connectionLifecycleDeadlineTask = nil
        let recoveryWasFailed = connectionLifecycle.recoveryFailed
        let effect = connectionLifecycle.complete(
            id: id,
            health: connectionLifecycleHealth(at: runtime?.now() ?? Date()),
            succeeded: succeeded
        )
        captureConnectionRecoveryFailureIfNeeded(wasFailed: recoveryWasFailed)
        resumeCompletedConnectionLifecycleRequests()
        if connectionLifecycleTask != nil,
           connectionLifecycle.activeEpisode?.id != id {
            connectionLifecycleTask = nil
        }
        applyConnectionLifecycleEffect(effect)
    }

    func recordConnectionRecoveryFailureWithoutEpisode() {
        let recoveryWasFailed = connectionLifecycle.recoveryFailed
        connectionLifecycle.markRecoveryFailed()
        captureConnectionRecoveryFailureIfNeeded(wasFailed: recoveryWasFailed)
    }

    private func resumeCompletedConnectionLifecycleRequests() {
        for requestID in connectionLifecycle.drainCompletedRequestIDs() {
            connectionLifecycleRequestWaiters.removeValue(forKey: requestID)?.resume()
        }
    }

    func freshReconnectRoutesAfterLocalFailure(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot,
        triedRoutes: [(host: String, port: Int, routeID: String)]
    ) async -> [(host: String, port: Int, routeID: String)]? {
        guard let deviceRegistry,
              await isScopeCurrent(scope),
              await !isForgottenMacDeviceID(mac.macDeviceID, scope: scope),
              let registryRoutes = await deviceRegistry.freshRoutes(forMacDeviceID: mac.macDeviceID),
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

    /// Writes the persisted paired-Mac hint only when `generation` is current.
    func setHasKnownPairedMac(_ value: Bool, generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        hasKnownPairedMac = value
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
