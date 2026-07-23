public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
public import CmuxMobileTransport
public import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

enum StoredMacReconnectOutcome: Equatable, Sendable {
    case connected
    case failed(DiagnosticFailureKind)
    case superseded

    var didConnect: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
extension MobileShellComposite {
    func startObservingNetworkPathChanges() {
        guard !networkPathObservationStarted else { return }
        networkPathObservationStarted = true
        let reachability = self.reachability
        networkPathObservationTask = Task { @MainActor [weak self] in
            // Each yield marks a meaningful path change (offline->online or a
            // primary-interface switch while online); recover the live
            // connection so a moving network repaints instead of going stale.
            for await _ in reachability.pathChanges() {
                guard let self, !Task.isCancelled else { return }
                let isOnline = await reachability.isOnline
                self.diagnosticLog?.record(DiagnosticEvent(
                    .reachabilityChanged,
                    a: isOnline ? 1 : 0
                ))
                self.recoverMobileConnection(trigger: .networkChange)
            }
        }
    }

    /// Foreground, network, presence, liveness, and stream-failure recovery all
    /// enter the same owner. Foreground starts with a positive-liveness probe;
    /// a failed probe promotes that exact attempt to one stored-Mac redial.
    func recoverForegroundConnectionIfNeeded(resyncAfterHealthy: Bool) {
        guard connectionState == .connected,
              let client = remoteClient,
              pairedMacStore != nil else { return }
        beginConnectionRecovery(
            trigger: .foreground,
            expectedClient: client,
            probeCurrentConnection: true,
            resyncAfterHealthy: resyncAfterHealthy
        )
    }

    /// Single guarded recovery entry for every trigger (network change, manual
    /// Retry). When still connected, a network move usually only broke the event
    /// stream while input keeps flowing over the surviving connection, so a
    /// resync re-subscribes and requests a render-grid replay to repaint.
    /// Otherwise the connection dropped, so reconnect once; on failure the UI
    /// shows Retry and the next network change re-attempts automatically.
    func recoverMobileConnection(trigger: RecoveryTrigger) {
        guard remoteClient != nil || pairedMacStore != nil else { return }
        if let accountID = identityProvider?.currentUserID {
            switch trigger {
            case .manual, .networkChange:
                clearTransientAutomaticReconnectBackoff(accountID: accountID)
            case .presencePush:
                guard !automaticIrohReconnectIsBlocked(accountID: accountID) else {
                    return
                }
            case .foreground, .liveness, .eventStreamEnded,
                 .subscriptionStartFailed, .transportWriteTimedOut,
                 .automaticBackoffExpired:
                break
            }
        }
        beginConnectionRecovery(
            trigger: trigger,
            expectedClient: remoteClient,
            probeCurrentConnection: connectionState == .connected && remoteClient != nil,
            resyncAfterHealthy: true
        )
        if multiMacAggregationEnabled, trigger.reschedulesSecondaryAggregation {
            scheduleSecondaryAggregation()
        }
    }

    /// A definitive event-stream failure bypasses same-client resubscription.
    /// Once the exact session is proven dead, rebuilding its listener only hides
    /// the failure behind the transport's reconnect behavior and leaves the
    /// shell owner stale. Instead, transition the one lifecycle owner to a fresh
    /// authenticated stored-Mac dial.
    func recoverDeadConnection(
        trigger: RecoveryTrigger,
        expectedClient: MobileCoreRPCClient
    ) {
        guard remoteClient === expectedClient, connectionState == .connected else { return }

        if connectionRecoveryOwner.isRedialingOrValidating {
            let replacementIsInstalled = connectionRecoveryOwner.isValidatingReplacement
                || connectionRecoveryOwner.activeAttempt?.sourceConnectionGeneration != connectionGeneration
            guard replacementIsInstalled else { return }
            guard failConnectionRecoveryReplacement(failure: .connectionClosed) else { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            applyConnectionRecoveryOwnerState()
            return
        }

        let superseding = connectionRecoveryOwner.supersedeProbeWithRedial(
            trigger: trigger.description,
            sourceConnectionGeneration: connectionGeneration
        )
        startConnectionRecovery(
            trigger: trigger,
            expectedClient: expectedClient,
            probeCurrentConnection: false,
            resyncAfterHealthy: false,
            preclaimedAttempt: superseding
        )
    }

    private func beginConnectionRecovery(
        trigger: RecoveryTrigger,
        expectedClient: MobileCoreRPCClient?,
        probeCurrentConnection: Bool,
        resyncAfterHealthy: Bool
    ) {
        startConnectionRecovery(
            trigger: trigger,
            expectedClient: expectedClient,
            probeCurrentConnection: probeCurrentConnection,
            resyncAfterHealthy: resyncAfterHealthy,
            preclaimedAttempt: nil
        )
    }

    private func startConnectionRecovery(
        trigger: RecoveryTrigger,
        expectedClient: MobileCoreRPCClient?,
        probeCurrentConnection: Bool,
        resyncAfterHealthy: Bool,
        preclaimedAttempt: MobileConnectionRecoveryOwner.Attempt?
    ) {
        guard pairedMacStore != nil else {
            guard connectionState == .connected else { return }
            // Preview/legacy clients can have a live RPC shell without durable
            // pairing state. Liveness and network-path changes can rebuild that
            // listener on the existing client, but a definitively ended stream
            // cannot safely invent a redial route and must remain unavailable.
            switch trigger {
            case .liveness, .networkChange:
                markMacConnectionReconnecting()
                resyncTerminalOutput(reason: trigger.description, restartEventStream: true)
            case .manual, .presencePush, .foreground, .eventStreamEnded,
                 .subscriptionStartFailed, .transportWriteTimedOut, .automaticBackoffExpired:
                markMacConnectionUnavailableIfNoStore()
            }
            return
        }
        let attempt = preclaimedAttempt ?? connectionRecoveryOwner.begin(
            trigger: trigger.description,
            sourceConnectionGeneration: connectionGeneration,
            probing: probeCurrentConnection
        )
        guard let attempt else { return }
        diagnosticLog?.record(DiagnosticEvent(
            .recoveryStarted,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue,
            b: trigger.diagnosticCode
        ))
        applyConnectionRecoveryOwnerState()
        let stackUserID = lastReconnectStackUserID ?? identityProvider?.currentUserID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskCancellationHandler {
                defer { self.connectionRecoveryOwner.clearTask(for: attempt) }
                guard self.connectionRecoveryOwner.isCurrent(attempt) else { return }

                if probeCurrentConnection, let expectedClient {
                    let healthy = await self.reloadWorkspaceListFromMac(
                        timeoutNanoseconds: self.runtime?.livenessProbeTimeoutNanoseconds
                    )
                    guard !Task.isCancelled,
                          self.connectionRecoveryOwner.isCurrent(attempt),
                          self.remoteClient === expectedClient,
                          self.connectionGeneration == attempt.sourceConnectionGeneration else {
                        return
                    }
                    if healthy {
                        guard self.completeConnectionRecovery(attempt) else { return }
                        self.markMacConnectionHealthy()
                        if resyncAfterHealthy {
                            self.resyncTerminalOutput(
                                reason: "connectionRecovery.\(trigger)",
                                restartEventStream: true
                            )
                        }
                        self.applyConnectionRecoveryOwnerState()
                        return
                    }
                }

                guard !Task.isCancelled,
                      self.connectionRecoveryOwner.transitionToRedialing(attempt) else { return }
                if let expectedClient {
                    guard self.remoteClient === expectedClient else { return }
                    // Detach the stale shell synchronously on the main actor
                    // before awaiting its transport teardown. This cancels every
                    // tracked producer and makes untracked producers fail their
                    // identity guard, so they cannot reopen the old endpoint
                    // while the fresh stored-Mac dial starts.
                    self.connectionState = .disconnected
                    self.macConnectionStatus = .unavailable
                    self.clearRemoteConnectionContext()
                    self.applyConnectionRecoveryOwnerState()
                    await expectedClient.disconnect()
                    guard !Task.isCancelled,
                          self.connectionRecoveryOwner.isCurrent(attempt) else { return }
                }
                if self.connectionState == .connected {
                    self.connectionState = .disconnected
                    self.macConnectionStatus = .unavailable
                    self.clearRemoteConnectionContext()
                }
                self.applyConnectionRecoveryOwnerState()

                // Recovery uses authenticated local Iroh state first. A stuck
                // account-backup fetch must not block a known EndpointID from
                // dialing; normal launch reconnect still refreshes first. The
                // shared reconnect entry owns the hard deadline after claiming
                // its generation synchronously, so every lifecycle caller gets
                // the same wedge protection without a second race here.
                let reconnectOutcome = await self.reconnectActiveMacOutcome(
                    stackUserID: stackUserID,
                    refreshBackupBeforeDial: false
                )
                guard !Task.isCancelled,
                      self.connectionRecoveryOwner.isCurrent(attempt) else { return }
                guard self.settleConnectionRecovery(
                    attempt,
                    outcome: reconnectOutcome,
                    connectionGeneration: self.connectionGeneration
                ) else { return }
                self.applyConnectionRecoveryOwnerState()
            } onCancel: {
                MobileDebugLog.anchormux(
                    "connection.recovery cancelled trigger=\(trigger.description) attempt=\(attempt.id.uuidString)"
                )
            }
        }
        connectionRecoveryOwner.install(task, for: attempt)
    }

    @discardableResult
    func completeConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt
    ) -> Bool {
        guard connectionRecoveryOwner.complete(attempt) else { return false }
        recordConnectionRecoverySucceeded()
        return true
    }

    @discardableResult
    func settleSuccessfulConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt,
        connectionGeneration: UUID
    ) -> Bool {
        if lastSuccessfulTerminalSubscriptionGeneration == connectionGeneration {
            return completeConnectionRecovery(attempt)
        }
        return connectionRecoveryOwner.transitionToValidation(
            attempt,
            connectionGeneration: connectionGeneration
        )
    }

    @discardableResult
    func settleConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt,
        outcome: StoredMacReconnectOutcome,
        connectionGeneration: UUID
    ) -> Bool {
        switch outcome {
        case .connected:
            return settleSuccessfulConnectionRecovery(
                attempt,
                connectionGeneration: connectionGeneration
            )
        case .failed(let failure):
            return failConnectionRecovery(attempt, failure: failure)
        case .superseded:
            return failConnectionRecovery(attempt, failure: .superseded)
        }
    }

    @discardableResult
    func failConnectionRecovery(
        _ attempt: MobileConnectionRecoveryOwner.Attempt,
        failure: DiagnosticFailureKind
    ) -> Bool {
        guard connectionRecoveryOwner.fail(attempt) else { return false }
        recordConnectionRecoveryFailed(failure)
        return true
    }

    @discardableResult
    func failConnectionRecoveryReplacement(
        failure: DiagnosticFailureKind
    ) -> Bool {
        guard connectionRecoveryOwner.failReplacement() != nil else { return false }
        recordConnectionRecoveryFailed(failure)
        return true
    }

    private func recordConnectionRecoverySucceeded() {
        diagnosticLog?.record(DiagnosticEvent(
            .recoverySucceeded,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue
        ))
    }

    private func recordConnectionRecoveryFailed(_ failure: DiagnosticFailureKind) {
        diagnosticLog?.record(DiagnosticEvent(
            .recoveryFailed,
            a: activeRoute.map { DiagnosticTransportKind($0.kind).rawValue }
                ?? DiagnosticTransportKind.unknown.rawValue,
            b: failure.rawValue
        ))
    }

    func recordSuccessfulTerminalSubscription() {
        lastSuccessfulTerminalSubscriptionGeneration = connectionGeneration
        if connectionRecoveryOwner.completeValidation(connectionGeneration: connectionGeneration) {
            recordConnectionRecoverySucceeded()
            applyConnectionRecoveryOwnerState()
        }
    }

    func applyConnectionRecoveryOwnerState() {
        switch connectionRecoveryOwner.phase {
        case .idle:
            isRecoveringConnection = false
            connectionRecoveryFailed = false
        case .probing, .redialing, .validatingReplacement:
            isRecoveringConnection = true
            connectionRecoveryFailed = false
            if connectionState == .connected { markMacConnectionReconnecting() }
        case .failed:
            isRecoveringConnection = false
            connectionRecoveryFailed = true
        }
    }

    private func markMacConnectionUnavailableIfNoStore() {
        macConnectionStatus = .unavailable
        isRecoveringConnection = false
        connectionRecoveryFailed = true
    }

    static func storedMacTicket(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "stored-workspace",
            terminalID: nil,
            macDeviceID: pairedMacDeviceID,
            macDisplayName: name,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: routes
        )
    }

    /// Reconnects an already-paired Mac through its full route set.
    ///
    /// This path is used only when the set contains an authenticated Iroh peer
    /// route or an exact locally grandfathered Tailscale route. Iroh pins the
    /// pairing and removes raw fallbacks; the Tailscale exception is bound to
    /// the previously paired device, address, and port. The synthetic ticket
    /// names the already-paired device and never creates a new pairing.
    func connectStoredMacRoutes(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        legacyTailscaleRoutes: [CmxAttachRoute] = [],
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        let ticket: CmxAttachTicket
        do {
            ticket = try Self.storedMacTicket(
                name: name,
                routes: routes,
                pairedMacDeviceID: pairedMacDeviceID
            )
            _ = try await connect(
                ticket: ticket,
                legacyTailscaleRoutes: legacyTailscaleRoutes,
                pairedMacDeviceID: pairedMacDeviceID,
                ifStillCurrent: ifStillCurrent
            )
        } catch {
            guard ifStillCurrent?() ?? true else { return }
            mobileShellLog.warning(
                "stored route reconnect failed mac=\(pairedMacDeviceID, privacy: .public) error=\(String(describing: error), privacy: .private)"
            )
            if disconnectForAuthorizationFailureIfNeeded(error) { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        }
    }

    /// Connects an existing pairing through its strongest supported transport.
    /// A supported Iroh identity pins the attempt to Iroh. Raw Tailscale/custom
    /// host routes remain available only for legacy pairings without Iroh.
    @discardableResult
    func connectStoredMac(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        legacyTailscaleRoutes: [CmxAttachRoute] = [],
        recordsPairingAttempt: Bool = false,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        (await connectStoredMacOutcome(
            name: name,
            routes: routes,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTag: nil,
            legacyTailscaleRoutes: legacyTailscaleRoutes,
            recordsPairingAttempt: recordsPairingAttempt,
            ifStillCurrent: ifStillCurrent
        )).didConnect
    }

    func connectStoredMacHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String,
        instanceTag: String? = nil,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTagExpectation: MobileMacInstanceTagAuthority.expectation(
                storedInstanceTag: instanceTag
            ),
            recordsPairingAttempt: false,
            ifStillCurrent: ifStillCurrent
        )
    }

    /// Reconnects a stored Mac through its Iroh-pinned route set while also
    /// enforcing the authenticated app-instance authority captured by storage.
    @discardableResult
    func connectStoredMac(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        instanceTag: String?,
        legacyTailscaleRoutes: [CmxAttachRoute] = [],
        automaticReconnectAccountID: String? = nil,
        recordsPairingAttempt: Bool = false,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        (await connectStoredMacOutcome(
            name: name,
            routes: routes,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTag: instanceTag,
            legacyTailscaleRoutes: legacyTailscaleRoutes,
            automaticReconnectAccountID: automaticReconnectAccountID,
            recordsPairingAttempt: recordsPairingAttempt,
            ifStillCurrent: ifStillCurrent
        )).didConnect
    }

    func connectStoredMacOutcome(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        instanceTag: String?,
        legacyTailscaleRoutes: [CmxAttachRoute] = [],
        automaticReconnectAccountID: String? = nil,
        recordsPairingAttempt: Bool = false,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> StoredMacReconnectOutcome {
        await connectStoredMacOutcome(
            name: name,
            routes: routes,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTagExpectation: MobileMacInstanceTagAuthority.expectation(
                storedInstanceTag: instanceTag
            ),
            legacyTailscaleRoutes: legacyTailscaleRoutes,
            automaticReconnectAccountID: automaticReconnectAccountID,
            recordsPairingAttempt: recordsPairingAttempt,
            ifStillCurrent: ifStillCurrent
        )
    }

    /// Connects through a stored route set while enforcing the caller's exact
    /// authenticated instance-authority requirement.
    @discardableResult
    private func connectStoredMacOutcome(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        instanceTagExpectation: MobileMacInstanceTagExpectation,
        legacyTailscaleRoutes: [CmxAttachRoute] = [],
        automaticReconnectAccountID: String? = nil,
        recordsPairingAttempt: Bool = false,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> StoredMacReconnectOutcome {
        guard ifStillCurrent?() ?? true else { return .superseded }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let pinnedRoutes = Self.storedReconnectRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard let firstRoute = pinnedRoutes.first else { return .failed(.unsupportedRoute) }

        var outcome: StoredMacReconnectOutcome = .failed(.unknown)

        let hasAuthorizedLegacyTailscaleRoute = pinnedRoutes.contains { route in
            Self.legacyTailscaleAuthorizationEvidence(
                for: route,
                macDeviceID: pairedMacDeviceID,
                persistedRoutes: legacyTailscaleRoutes
            ) != nil
        }
        if firstRoute.kind == .iroh || hasAuthorizedLegacyTailscaleRoute {
            do {
                let ticket = try Self.storedMacTicket(
                    name: name,
                    routes: pinnedRoutes,
                    pairedMacDeviceID: pairedMacDeviceID
                )
                let noThrowFailure = try await connect(
                    ticket: ticket,
                    legacyTailscaleRoutes: legacyTailscaleRoutes,
                    pairedMacDeviceID: pairedMacDeviceID,
                    instanceTagExpectation: instanceTagExpectation,
                    ifStillCurrent: ifStillCurrent
                )
                guard ifStillCurrent?() ?? true else { return .superseded }
                if noThrowFailure == .noSupportedRoute {
                    outcome = .failed(.unsupportedRoute)
                }
            } catch {
                guard ifStillCurrent?() ?? true else { return .superseded }
                outcome = .failed(Self.diagnosticFailureKind(for: error))
                if let automaticReconnectAccountID {
                    recordAutomaticReconnectBackoff(
                        error: error,
                        accountID: automaticReconnectAccountID
                    )
                }
                if !disconnectForAuthorizationFailureIfNeeded(error) {
                    connectionState = .disconnected
                    macConnectionStatus = .unavailable
                    clearRemoteConnectionContext()
                }
            }
        } else {
            let candidates = Self.reconnectHostPortRoutes(
                pinnedRoutes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
            for route in candidates {
                guard ifStillCurrent?() ?? true else { return .superseded }
                await connectManualHost(
                    name: name,
                    host: route.host,
                    port: route.port,
                    pairedMacDeviceID: pairedMacDeviceID,
                    instanceTagExpectation: instanceTagExpectation,
                    recordsPairingAttempt: recordsPairingAttempt,
                    ifStillCurrent: ifStillCurrent
                )
                if connectionState == .connected,
                   remoteClient != nil,
                   foregroundMacDeviceID == pairedMacDeviceID {
                    break
                }
            }
        }

        let connected = (ifStillCurrent?() ?? true)
            && connectionState == .connected
            && remoteClient != nil
            && foregroundMacDeviceID == pairedMacDeviceID
        if connected, let automaticReconnectAccountID {
            clearAutomaticReconnectBackoff(accountID: automaticReconnectAccountID)
        }
        return connected ? .connected : outcome
    }

    func automaticIrohReconnectIsBlocked(accountID: String) -> Bool {
        automaticReconnectBackoffOwner.isBlocked(
            accountID: accountID,
            now: runtime?.now() ?? Date()
        )
    }

    func recordAutomaticReconnectBackoff(error: any Error, accountID: String) {
        guard let retryAfterError = error as? any CmxRetryAfterProviding,
              let retryAfterSeconds = retryAfterError.retryAfterSeconds else { return }
        let now = runtime?.now() ?? Date()
        let retryAt = automaticReconnectBackoffOwner.record(
            accountID: accountID,
            retryAfterSeconds: retryAfterSeconds,
            now: now
        )
        scheduleAutomaticReconnectRetry(accountID: accountID, retryAt: retryAt, now: now)
    }

    func recordTransientAutomaticReconnectBackoff(accountID: String) {
        let now = runtime?.now() ?? Date()
        let retryAt = automaticReconnectBackoffOwner.recordTransientFailure(
            accountID: accountID,
            now: now
        )
        scheduleAutomaticReconnectRetry(accountID: accountID, retryAt: retryAt, now: now)
    }

    func clearTransientAutomaticReconnectBackoff(accountID: String) {
        automaticReconnectBackoffOwner.clearTransientCooldown(accountID: accountID)
        let now = runtime?.now() ?? Date()
        if let retryAt = automaticReconnectBackoffOwner.retryAt, retryAt > now {
            scheduleAutomaticReconnectRetry(accountID: accountID, retryAt: retryAt, now: now)
        } else {
            automaticReconnectRetryTask?.cancel()
            automaticReconnectRetryTask = nil
            automaticReconnectRetryAccountID = nil
            automaticReconnectRetryAt = nil
        }
    }

    func clearAutomaticReconnectBackoff(accountID: String? = nil) {
        automaticReconnectBackoffOwner.clear(accountID: accountID)
        guard accountID == nil || automaticReconnectBackoffOwner.accountID == nil else { return }
        automaticReconnectRetryTask?.cancel()
        automaticReconnectRetryTask = nil
        automaticReconnectRetryAccountID = nil
        automaticReconnectRetryAt = nil
    }

    private func scheduleAutomaticReconnectRetry(
        accountID: String,
        retryAt: Date,
        now: Date
    ) {
        if automaticReconnectRetryTask != nil,
           automaticReconnectRetryAccountID == accountID,
           automaticReconnectRetryAt == retryAt {
            return
        }
        automaticReconnectRetryTask?.cancel()
        automaticReconnectRetryAccountID = accountID
        automaticReconnectRetryAt = retryAt
        let delay = max(0, retryAt.timeIntervalSince(now))
        automaticReconnectRetryTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.identityProvider?.currentUserID == accountID,
                  self.automaticReconnectBackoffOwner.accountID == accountID,
                  self.automaticReconnectRetryAccountID == accountID,
                  self.automaticReconnectRetryAt == retryAt else { return }
            self.automaticReconnectRetryTask = nil
            self.automaticReconnectRetryAccountID = nil
            self.automaticReconnectRetryAt = nil
            guard self.isSignedIn, self.connectionState != .connected else { return }
            let currentNow = self.runtime?.now() ?? Date()
            if self.automaticReconnectBackoffOwner.isBlocked(
                accountID: accountID,
                now: currentNow
            ), let nextRetryAt = self.automaticReconnectBackoffOwner.retryAt {
                self.scheduleAutomaticReconnectRetry(
                    accountID: accountID,
                    retryAt: nextRetryAt,
                    now: currentNow
                )
                return
            }
            self.recoverMobileConnection(trigger: .automaticBackoffExpired)
        }
    }

    /// Connect the live session to a specific registry app instance (a tag on a
    /// device) using that instance's advertised routes.
    ///
    /// This is the device tree's tap-to-open for a tag that is not the currently
    /// connected one: it routes through the same destructive ``connectManualHost``
    /// path the multi-Mac switcher uses, then persists the device as the active
    /// paired Mac on success (so a later relaunch reconnects to it) and refreshes
    /// the paired-Mac list. A no-op when the instance advertises no reachable
    /// route. Failure surfaces through ``connectionError`` like any other connect.
    ///
    /// Like ``switchToMac(macDeviceID:)``, the connect is destructive (it replaces
    /// the live client), so tapping a stale/offline tag while connected would drop
    /// a healthy session. To avoid stranding the user, on a failed connect the
    /// previously-active Mac is reconnected, so a bad target leaves the user where
    /// they were rather than disconnected.
    /// - Parameters:
    ///   - device: The registry device the instance belongs to.
    ///   - instance: The tag/app-instance to connect to.
    public func connectToRegistryInstance(
        device: RegistryDevice,
        instance: RegistryAppInstance
    ) async {
        let scope = await currentScopeSnapshot()
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let candidateRoutes = Self.storedReconnectRoutes(
            instance.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard !candidateRoutes.isEmpty else {
            mobileShellLog.error(
                "connectToRegistryInstance: no reconnectable route device=\(device.deviceId, privacy: .public) tag=\(instance.tag, privacy: .public)"
            )
            return
        }
        if connectionState == .connected,
           connectedMacDeviceID == device.deviceId,
           activeMacInstanceTag == instance.tag,
           let liveRoute = activeRoute,
           candidateRoutes.contains(where: {
               $0.id == liveRoute.id || $0.endpoint == liveRoute.endpoint
           }) {
            return
        }
        let previousActive = pairedMacs.first { $0.isActive }
        let connectedRoute = (await connectStoredMacOutcome(
            name: device.displayName ?? device.deviceId,
            routes: candidateRoutes,
            pairedMacDeviceID: device.deviceId,
            instanceTagExpectation: .require(instance.tag),
            recordsPairingAttempt: true
        )).didConnect
        guard connectedRoute else {
            if previousActive != nil, connectionState != .connected {
                _ = await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID)
            }
            return
        }
        if let scope, await !isScopeCurrent(scope) { return }
        await loadPairedMacs()
        await loadRegistryDevices()
    }

    /// Connect a live account-discovered Iroh Mac while requiring its broker
    /// advertised app-instance tag.
    @discardableResult
    func connectAccountDiscoveredIrohMac(
        _ mac: MobileDiscoveredIrohMac,
        accountID: String,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let candidateRoutes = Self.storedReconnectRoutes(
            mac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard candidateRoutes.contains(where: { $0.kind == .iroh }) else { return false }
        return (await connectStoredMacOutcome(
            name: mac.displayName ?? mac.deviceID,
            routes: candidateRoutes,
            pairedMacDeviceID: mac.deviceID,
            instanceTagExpectation: .require(mac.instanceTag),
            automaticReconnectAccountID: accountID,
            ifStillCurrent: ifStillCurrent
        )).didConnect
    }

    /// Re-fetch the authoritative workspace list from the connected Mac and apply
    /// it, awaiting the round-trip to completion.
    @discardableResult
    func reloadWorkspaceListFromMac(
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        // While state sync v2 owns the list, do not build/serialize/send the
        // legacy full list at all (the Computers screen refreshes through here
        // every 10s; paying the full-list cost and discarding it defeats the
        // delta protocol). The cursor fetch is both the liveness probe and the
        // authoritative refresh, AWAITED so pull-to-refresh cannot report done
        // before state applied, with the caller's probe timeout honored.
        if stateSyncActive {
            return await performStateSyncFetch(client: client, timeoutNanoseconds: timeoutNanoseconds)
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.workspace.list",
                params: [:]
            )
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: timeoutNanoseconds ?? runtime?.rpcRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(data)
            guard remoteClient === client, connectionState == .connected else { return false }
            // Re-check authority AFTER the await: negotiation can grant v2 in
            // the window while this legacy request was in flight, and applying
            // the captured full list then would overwrite newer mirror state.
            // The round-trip already proved liveness; the v2 mirror owns the
            // list, so report success without applying.
            if stateSyncActive { return true }
            applyRemoteWorkspaceList(response, preferActiveTicketTarget: false)
            syncSelectedTerminalForWorkspace()
            return true
        } catch {
            mobileShellLog.error(
                "workspace list event refresh failed: \(String(describing: error), privacy: .private)"
            )
            if remoteClient === client {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
    }

    /// - Parameter pairedMacDeviceID: the REAL paired-Mac device id when the caller
    ///   knows it (switch/reconnect/device-row paths). A manual host whose Mac lacks
    ///   `mobile.attach_ticket.create` connects via a synthetic `manual-…` ticket;
    ///   passing the real id keys the foreground aggregate state under it instead of
    ///   the synthetic id. `nil` for a genuinely manual/unknown host.

    /// Races `operation` against a wall-clock deadline. Returns the
    /// operation's value, or `nil` when the deadline expires first.
    ///
    /// Deliberately UNSTRUCTURED: a task group would structurally await the
    /// losing child, so a dial that ignores cancellation (the exact wedge
    /// this exists for) would suspend the race forever. Instead the
    /// operation runs in its own task that the deadline path abandons after
    /// a best-effort cancel; the once-guard is MainActor-confined so exactly
    /// one side resumes. An abandoned dial retains its captures until it
    /// eventually resolves — bounded by transport teardown and precisely the
    /// cost of not being wedged.
    /// Ceiling on concurrently outstanding abandoned (wedged) dials before
    /// automatic retries pause. A dial that resolves reclaims its slot and
    /// re-arms the automatic retry when still disconnected.
    static var maximumAbandonedReconnectDials: Int { 3 }

    /// Tracks an abandoned dial until it resolves, so a persistently wedged
    /// transport cannot accumulate an unbounded set of retained reconnect
    /// tasks across automatic retries. On resolution, if the shell is still
    /// signed in and disconnected, the automatic retry loop is re-armed
    /// (covers the case where retries were paused at the ceiling).
    func registerAbandonedReconnectDial(_ task: Task<StoredMacReconnectOutcome, Never>?) {
        guard let task else { return }
        abandonedReconnectDialCount += 1
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self else { return }
            self.abandonedReconnectDialCount = max(0, self.abandonedReconnectDialCount - 1)
            // Re-arm the retry loop directly through the coalesced recovery
            // entry, NEVER by recording backoff: a backoff write here can land
            // mid-manual-retry and re-block the dial the user just requested
            // (manual retries clear backoff on entry). Skip when any attempt
            // or scheduled retry is already active.
            guard self.isSignedIn, self.connectionState != .connected,
                  !self.connectionRecoveryOwner.isRedialingOrValidating,
                  self.automaticReconnectRetryTask == nil else { return }
            self.recoverMobileConnection(trigger: .automaticBackoffExpired)
        }
    }

    /// The race result: `value` is nil when the deadline won, in which case
    /// `abandoned` is the still-running operation task so the caller can
    /// bound how many abandoned dials may exist at once and reclaim the slot
    /// when the task eventually resolves.
    struct DeadlineRaceOutcome<Value: Sendable>: Sendable {
        let value: Value?
        let abandoned: Task<Value, Never>?
    }

    static func raceAgainstDeadline<Value: Sendable>(
        nanoseconds: UInt64,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> DeadlineRaceOutcome<Value> {
        let operationTask = Task { await operation() }
        // The operation runs unstructured (so a cancellation-ignoring dial
        // cannot park the race past its deadline), which severs implicit
        // cancellation inheritance — forward the caller's cancellation
        // explicitly so a superseded recovery attempt still aborts a
        // well-behaved dial immediately.
        let value: Value? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let once = RaceContinuationOnce(continuation)
                Task {
                    once.finish(await operationTask.value)
                }
                Task {
                    // Intentional bounded deadline timer (not a polling wait);
                    // cancellation of the race cancels the operation via the
                    // handler above, and this timer resolves the race at the
                    // bound either way.
                    try? await ContinuousClock().sleep(for: .nanoseconds(Int64(nanoseconds)))
                    operationTask.cancel()
                    once.finish(nil)
                }
            }
        } onCancel: {
            operationTask.cancel()
        }
        return DeadlineRaceOutcome(
            value: value,
            abandoned: value == nil ? operationTask : nil
        )
    }
}

/// Resumes a race continuation exactly once, whichever side finishes first.
/// Lock-based rather than actor-based so both racing tasks can call it
/// without an isolation hop.
private final class RaceContinuationOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
