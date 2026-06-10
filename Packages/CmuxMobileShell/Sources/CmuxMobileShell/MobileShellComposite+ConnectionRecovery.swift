public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import CmuxMobileTransport
public import Foundation
import Observation
internal import OSLog


// MARK: - Network recovery and Mac reconnect
extension MobileShellComposite {
    private enum RecoveryTrigger: CustomStringConvertible {
        case networkChange
        case manual
        var description: String {
            switch self {
            case .networkChange: return "networkChange"
            case .manual: return "manual"
            }
        }
    }

    /// Begin observing meaningful network path changes (Wi-Fi<->cellular,
    /// offline->online) so a live terminal recovers when the network moves out
    /// from under it. Idempotent; only the first call arms the observation.
    func startObservingNetworkPathChanges() {
        guard !networkPathObservationStarted else { return }
        networkPathObservationStarted = true
        let reachability = reachability
        networkPathObservationTask = Task { @MainActor [weak self] in
            // Each yield marks a meaningful path change (offline->online or a
            // primary-interface switch while online); recover the live
            // connection so a moving network repaints instead of going stale.
            for await _ in reachability.pathChanges() {
                guard let self, !Task.isCancelled else { return }
                self.recoverMobileConnection(trigger: .networkChange)
            }
        }
    }

    /// User-initiated reconnect from the Retry control.
    public func retryMobileConnection() {
        connectionRecoveryFailed = false
        recoverMobileConnection(trigger: .manual)
    }

    /// Single guarded recovery entry for every trigger (network change, manual
    /// Retry). When still connected, a network move usually only broke the event
    /// stream while input keeps flowing over the surviving connection, so a
    /// resync re-subscribes and requests a render-grid replay to repaint.
    /// Otherwise the connection dropped, so reconnect once; on failure the UI
    /// shows Retry and the next network change re-attempts automatically.
    private func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        if connectionState == .connected, remoteClient != nil {
            markMacConnectionReconnecting()
            resyncTerminalOutput(reason: "networkRecovery.\(trigger)", restartEventStream: true)
            return
        }
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        isRecoveringConnection = true
        connectionRecoveryFailed = false
        let stackUserID = lastReconnectStackUserID
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            defer {
                self?.recoveryInFlight = false
                self?.isRecoveringConnection = false
            }
            guard let self, self.connectionState != .connected else { return }
            let reconnected = await self.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
            if !reconnected, !Task.isCancelled {
                self.connectionRecoveryFailed = true
            }
        }
    }

    public func connectPreviewHost() {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            return
        }
        let attemptID = beginPairingAttempt()
        replaceRemoteClient(with: nil)
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        connectedHostName = PreviewMobileHost.hostName
        guard isCurrentPairingAttempt(attemptID) else { return }
        connectionState = .connected
        markMacConnectionHealthy()
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedTerminalForWorkspace()
    }

    public func connectPairingInput() async {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            await connectPairingURL(trimmedCode)
            return
        }
        connectPreviewHost()
    }

    public func connectManualHost(name: String, host: String, port: Int) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            connectionError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_host"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_port"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return
        }

        let directRoute = try? Self.manualHostRoute(host: normalizedHost, port: port)
        let attemptID = beginPairingAttempt(method: "manual")
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            try await connect(ticket: ticket, allowsStackAuthFallback: true)
            guard isCurrentPairingAttempt(attemptID) else { return }
            if connectionState == .connected {
                recordPairingSucceeded()
            } else {
                recordPairingFailed(reason: "other", phase: "connect")
            }
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return }
            mobileShellLog.error("manual host pairing failed: \(String(describing: error), privacy: .private)")
            // A definitive auth failure (expired/invalid token after the
            // refresh-then-retry in the RPC layer already gave up) must drive the
            // re-auth prompt, not the generic "could not connect / Retry" banner.
            if disconnectForAuthorizationFailureIfNeeded(error) {
                recordPairingFailed(reason: "account_mismatch", phase: "auth")
                return
            }
            recordPairingFailed(reason: Self.pairingFailureReason(for: error), phase: "connect")
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute ?? directRoute)
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        }
    }

    /// On launch (after StackAuth has bootstrapped), call this to reconnect
    /// to the last-active paired Mac. Pulls (route, displayName, macDeviceID)
    /// from SQLite and re-mints an attach ticket via the StackAuth-authenticated
    /// manual host flow. Auth tokens never persist; we always re-mint.
    @discardableResult
    public func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool {
        lastReconnectStackUserID = stackUserID
        startObservingNetworkPathChanges()
        // Claim this attempt's generation. Only the current generation may resolve
        // the restoring-gate flags, so an older superseded attempt can't clear the
        // gate (or clobber the hint) while a newer reconnect is still running.
        storedMacReconnectGeneration &+= 1
        let generation = storedMacReconnectGeneration
        // No store / not signed in: can't determine a stored Mac here. Resolve the
        // restoring gate (so a returning user doesn't spin on RestoringSessionView)
        // but leave the persisted hint intact for a future attempt.
        guard let pairedMacStore else {
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        guard isSignedIn else {
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        let saved: MobilePairedMac?
        do {
            saved = try await pairedMacStore.activeMac(stackUserID: stackUserID)
        } catch {
            mobileShellLog.error("paired mac store activeMac failed: \(String(describing: error), privacy: .public)")
            // A read failure means "couldn't determine," not "no mac": keep the
            // hint so a transient SQLite error doesn't erase a returning user's
            // paired state.
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        guard let mac = saved else {
            // Definitively no active Mac: clear the hint so future launches show
            // the add-device sheet immediately with no restoring flash.
            setHasKnownPairedMac(false, generation: generation)
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        // Kick off a best-effort registry refresh for this Mac in the background.
        // It does NOT block the connect below: the common case (fresh local
        // routes) reconnects immediately with no network round-trip. If the Mac
        // moved networks / changed port, the refreshed routes land in the store
        // and the next reconnect trigger (network change or Retry) uses them.
        refreshRoutesFromRegistry(for: mac, stackUserID: stackUserID)
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            mac.routes,
            supportedKinds: supportedKinds
        ) else {
            // Found a Mac but no usable route to reach it: treat as no reconnect
            // target and fall through to add-device.
            setHasKnownPairedMac(false, generation: generation)
            finishStoredMacReconnectAttempt(generation: generation)
            return false
        }
        // A newer attempt may have started while we awaited the store read; if so,
        // let it own the flags rather than marking ourselves the active reconnect.
        guard generation == storedMacReconnectGeneration else { return false }
        setHasKnownPairedMac(true, generation: generation)
        isReconnectingStoredMac = true
        // Cap how long the restoring gate stays up: a stored Mac whose route went
        // stale (Tailscale address changed, or it's offline) makes connectManualHost
        // hang on a slow connect timeout, and the gate shows RestoringSessionView for
        // that whole time. After the deadline, resolve the gate so the user reaches
        // add-device quickly; the connect keeps trying, so a later success still
        // flips connectionState to .connected and shows the workspaces.
        let restoringDeadline = Task { [weak self] in
            // Bounded, cancellable deadline (not a poll) — cancelled the instant the
            // connect resolves; only caps the restoring-gate window.
            try? await ContinuousClock().sleep(
                for: .seconds(Self.storedMacReconnectRestoringDeadlineSeconds)
            )
            guard let self, !Task.isCancelled,
                  generation == self.storedMacReconnectGeneration,
                  self.connectionState != .connected else { return }
            self.isReconnectingStoredMac = false
            self.didFinishStoredMacReconnectAttempt = true
        }
        await connectManualHost(name: mac.displayName ?? host, host: host, port: port)
        restoringDeadline.cancel()
        // A newer attempt may have started during the connect; it now owns the flags.
        guard generation == storedMacReconnectGeneration else { return false }
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
        return connectionState == .connected
    }

    /// Writes the persisted paired-Mac hint only when `generation` is still the
    /// current reconnect attempt, so a superseded attempt can't clobber a newer
    /// attempt's determination.
    private func setHasKnownPairedMac(_ value: Bool, generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        hasKnownPairedMac = value
    }

    /// Mark the stored-Mac reconnect attempt resolved without a live connection,
    /// but only when `generation` is still current.
    ///
    /// Clears ``isReconnectingStoredMac`` and sets
    /// ``didFinishStoredMacReconnectAttempt`` so the root scene falls through to
    /// the disconnected/add-device view instead of spinning on the restoring UI.
    /// A superseded attempt (older `generation`) is a no-op so it can't resolve the
    /// gate while a newer reconnect is in progress.
    private func finishStoredMacReconnectAttempt(generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
    }

    /// Best-effort, non-blocking registry refresh for the active paired Mac.
    ///
    /// Runs detached so it never adds latency to the in-flight reconnect (which
    /// connects on the locally persisted routes). When the registry returns
    /// usable, *different* routes for this Mac, they are written back into the
    /// store so the next reconnect trigger (network change / Retry) reaches the
    /// Mac at its current address after it moved networks or changed port. A
    /// missing registry, an unauthorized call, or no-change routes are no-ops, so
    /// a registry outage never disturbs the locally stored routes.
    private func refreshRoutesFromRegistry(for mac: MobilePairedMac, stackUserID: String?) {
        guard let deviceRegistry, let pairedMacStore else { return }
        let macDeviceID = mac.macDeviceID
        let localRoutes = mac.routes
        let displayName = mac.displayName
        Task { [weak self] in
            let registryRoutes = await deviceRegistry.freshRoutes(forMacDeviceID: macDeviceID)
            guard let updated = DeviceRegistryService.selectReconnectRoutes(
                local: localRoutes,
                registry: registryRoutes
            ) else { return }
            guard let self else { return }
            // The network await above suspended; the user may have signed out,
            // switched accounts, forgotten this Mac, or switched the active Mac
            // meanwhile. Re-evaluate against the *current* store/identity before
            // the `markActive: true` upsert, so a stale refresh can never
            // resurrect or reactivate a pairing the user removed. Mirrors the
            // user-switch guard in `loadPairedMacs`.
            let activeMacID: String?
            do {
                activeMacID = try await pairedMacStore.activeMac(stackUserID: stackUserID)?.macDeviceID
            } catch {
                mobileShellLog.debug("registry refresh active-mac recheck failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard DeviceRegistryService.shouldApplyRegistryRefresh(
                isSignedIn: self.isSignedIn,
                capturedUserID: stackUserID,
                currentUserID: self.identityProvider?.currentUserID,
                activeMacID: activeMacID,
                targetMacID: macDeviceID
            ) else { return }
            do {
                try await pairedMacStore.upsert(
                    macDeviceID: macDeviceID,
                    displayName: displayName,
                    routes: updated,
                    markActive: true,
                    stackUserID: stackUserID
                )
            } catch {
                mobileShellLog.debug("registry route refresh upsert failed: \(String(describing: error), privacy: .public)")
                return
            }
            await self.loadPairedMacs()
        }
    }

    // MARK: - Paired Mac switching

}
