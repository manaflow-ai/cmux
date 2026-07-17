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
            _ = connectionRecoveryOwner.failReplacement()
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
                 .subscriptionStartFailed, .transportWriteTimedOut:
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
                        _ = self.connectionRecoveryOwner.complete(attempt)
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
                // dialing; normal launch reconnect still refreshes first.
                let reconnected = await self.reconnectActiveMacIfAvailable(
                    stackUserID: stackUserID,
                    refreshBackupBeforeDial: false
                )
                guard !Task.isCancelled,
                      self.connectionRecoveryOwner.isCurrent(attempt) else { return }
                if reconnected {
                    let generation = self.connectionGeneration
                    if self.lastSuccessfulTerminalSubscriptionGeneration == generation {
                        _ = self.connectionRecoveryOwner.complete(attempt)
                    } else {
                        _ = self.connectionRecoveryOwner.transitionToValidation(
                            attempt,
                            connectionGeneration: generation
                        )
                    }
                } else {
                    _ = self.connectionRecoveryOwner.fail(attempt)
                }
                self.applyConnectionRecoveryOwnerState()
            } onCancel: {
                MobileDebugLog.anchormux(
                    "connection.recovery cancelled trigger=\(trigger.description) attempt=\(attempt.id.uuidString)"
                )
            }
        }
        connectionRecoveryOwner.install(task, for: attempt)
    }

    func recordSuccessfulTerminalSubscription() {
        lastSuccessfulTerminalSubscriptionGeneration = connectionGeneration
        if connectionRecoveryOwner.completeValidation(connectionGeneration: connectionGeneration) {
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
    /// route. `connect(ticket:)` pins the pairing to Iroh, so an admission or
    /// revocation failure cannot downgrade to raw Tailscale/custom-network RPC.
    /// The synthetic ticket names the already-paired device; it is never used to
    /// discover or create a new pairing.
    func connectStoredMacRoutes(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
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
        recordsPairingAttempt: Bool = false,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        guard ifStillCurrent?() ?? true else { return false }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let pinnedRoutes = Self.storedReconnectRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard let firstRoute = pinnedRoutes.first else { return false }

        if firstRoute.kind == .iroh {
            await connectStoredMacRoutes(
                name: name,
                routes: pinnedRoutes,
                pairedMacDeviceID: pairedMacDeviceID,
                ifStillCurrent: ifStillCurrent
            )
        } else {
            let candidates = Self.reconnectHostPortRoutes(
                pinnedRoutes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            ).filter { MobileShellRouteAuthPolicy.normalizedManualHost($0.host) != nil }
            for route in candidates {
                guard ifStillCurrent?() ?? true else { return false }
                if recordsPairingAttempt {
                    await connectManualHost(
                        name: name,
                        host: route.host,
                        port: route.port,
                        pairedMacDeviceID: pairedMacDeviceID,
                        recordsPairingAttempt: true,
                        ifStillCurrent: ifStillCurrent
                    )
                } else {
                    await connectStoredMacHost(
                        name: name,
                        host: route.host,
                        port: route.port,
                        pairedMacDeviceID: pairedMacDeviceID,
                        ifStillCurrent: ifStillCurrent
                    )
                }
                if connectionState == .connected,
                   remoteClient != nil,
                   foregroundMacDeviceID == pairedMacDeviceID {
                    break
                }
            }
        }

        return (ifStillCurrent?() ?? true)
            && connectionState == .connected
            && remoteClient != nil
            && foregroundMacDeviceID == pairedMacDeviceID
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
        recordsPairingAttempt: Bool = false,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        await connectStoredMac(
            name: name,
            routes: routes,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTagExpectation: MobileMacInstanceTagAuthority.expectation(
                storedInstanceTag: instanceTag
            ),
            recordsPairingAttempt: recordsPairingAttempt,
            ifStillCurrent: ifStillCurrent
        )
    }

    /// Connects through a stored route set while enforcing the caller's exact
    /// authenticated instance-authority requirement.
    @discardableResult
    private func connectStoredMac(
        name: String,
        routes: [CmxAttachRoute],
        pairedMacDeviceID: String,
        instanceTagExpectation: MobileMacInstanceTagExpectation,
        recordsPairingAttempt: Bool = false,
        ifStillCurrent: (() -> Bool)? = nil
    ) async -> Bool {
        guard ifStillCurrent?() ?? true else { return false }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let pinnedRoutes = Self.storedReconnectRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        guard let firstRoute = pinnedRoutes.first else { return false }

        if firstRoute.kind == .iroh {
            do {
                let ticket = try Self.storedMacTicket(
                    name: name,
                    routes: pinnedRoutes,
                    pairedMacDeviceID: pairedMacDeviceID
                )
                _ = try await connect(
                    ticket: ticket,
                    pairedMacDeviceID: pairedMacDeviceID,
                    instanceTagExpectation: instanceTagExpectation,
                    ifStillCurrent: ifStillCurrent
                )
            } catch {
                guard ifStillCurrent?() ?? true else { return false }
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
                guard ifStillCurrent?() ?? true else { return false }
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

        return (ifStillCurrent?() ?? true)
            && connectionState == .connected
            && remoteClient != nil
            && foregroundMacDeviceID == pairedMacDeviceID
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
        let connectedRoute = await connectStoredMac(
            name: device.displayName ?? device.deviceId,
            routes: candidateRoutes,
            pairedMacDeviceID: device.deviceId,
            instanceTagExpectation: .require(instance.tag),
            recordsPairingAttempt: true
        )
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

    /// Re-fetch the authoritative workspace list from the connected Mac and apply
    /// it, awaiting the round-trip to completion.
    @discardableResult
    func reloadWorkspaceListFromMac(
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        guard let client = remoteClient else { return false }
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
}
