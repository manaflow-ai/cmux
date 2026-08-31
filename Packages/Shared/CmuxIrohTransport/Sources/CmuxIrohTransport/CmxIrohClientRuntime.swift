public import CMUXMobileCore
public import Foundation

/// Owns one account-and-build-scoped iOS endpoint and its verified broker policy.
public actor CmxIrohClientRuntime {
    /// Runs after an exact local binding and discovery response have been verified.
    public typealias BindingHandler = @Sendable (
        _ binding: CmxIrohBrokerBinding,
        _ discovery: CmxIrohDiscoveryResponse
    ) async -> Bool

    /// Runs when connectivity-only startup restores signed, already-known Mac tuples.
    public typealias CachedBindingsHandler = @Sendable (
        _ bindings: [CmxIrohBrokerBinding],
        _ lanRendezvous: CmxIrohLANRendezvous
    ) async -> Void

    /// Supplies local-link reachability only for one authenticated Mac tuple.
    public typealias LANFallbackProvider = CmxIrohRegistryContextProvider.LANFallbackProvider
    public typealias CustomPrivateFallbackProvider =
        CmxIrohRegistryContextProvider.CustomPrivateFallbackProvider

    /// Runs after a relay credential is installed on the exact active binding.
    public typealias RelayCredentialHandler = @Sendable (
        _ response: CmxIrohRelayTokenResponse,
        _ binding: CmxIrohBrokerBinding
    ) async -> Void

    /// Removes account-local identity, binding, relay, and route cache state.
    public typealias LocalDeactivationHandler = @Sendable () async -> Void

    /// Removes persisted binding and route state after terminal broker evidence.
    public typealias PolicyInvalidationHandler = @Sendable () async -> Void

    struct ResolvedPolicy: Sendable {
        let registration: CmxIrohRegistrationResponse?
        let discovery: CmxIrohDiscoveryResponse?
        let binding: CmxIrohBrokerBinding
        let expectation: CmxIrohLocalBindingExpectation
        let offlineExpectation: CmxIrohClientOfflinePolicyExpectation?
        let cachedTargetBindings: [CmxIrohBrokerBinding]
        let cachedLANRendezvous: CmxIrohLANRendezvous?
    }

    private struct ConnectivityReconciliationOperation {
        let id: UUID
        let task: Task<CmxIrohLiveDiscoveryRefreshOutcome, Never>
    }

    enum LifecyclePhase: Equatable, Sendable {
        case inactive
        case starting
        case active
        case stopping
        case signingOut
        case quarantined
        case failed

        var allowsStart: Bool {
            self == .inactive || self == .failed
        }

        var ownsNetworkOperation: Bool {
            self == .starting || self == .active
        }
    }

    /// The route-aware factory registered by the iOS app before fallback transports.
    public nonisolated let transportFactory: CmxConnectivityByteTransportFactory

    let supervisor: CmxIrohEndpointSupervisor
    let connectivityEngine: CmxConnectivityEngine
    let contextRouter: CmxIrohRuntimeContextRouter
    let broker: any CmxIrohClientBrokerServing
    let configuration: CmxIrohClientRuntimeConfiguration
    var endpointRelayProfile: CmxIrohEndpointRelayProfile
    var managedRelayURLs: Set<String>
    let pendingRevocations: CmxIrohPendingRevocationOutbox
    let protocolConfiguration: CmxIrohProtocolConfiguration
    let offlinePolicyCache: CmxIrohClientOfflinePolicyCache?
    let networkPathSnapshot: @Sendable () async throws -> CmxIrohNetworkPathSnapshot
    let lanFallback: LANFallbackProvider?
    let customPrivateFallback: CustomPrivateFallbackProvider?
    let diagnosticLog: DiagnosticLog?
    let now: @Sendable () -> Date
    let automaticRelayCredentialRefreshEnabled: Bool
    let handleBinding: BindingHandler
    let handleCachedBindings: CachedBindingsHandler
    let handleRelayCredential: RelayCredentialHandler
    let handleLocalDeactivation: LocalDeactivationHandler
    let handlePolicyInvalidation: PolicyInvalidationHandler

    var lifecycleRevision: UInt64 = 0
    var lifecyclePhase = LifecyclePhase.inactive
    var signOutOperation: Task<CmxIrohClientSignOutPreparation, Never>?
    var relayCoordinator: CmxIrohRelayCredentialCoordinator?
    var supervisorEventTask: Task<Void, Never>?
    var registrationRefreshTask: Task<CmxIrohLiveDiscoveryRefreshOutcome, any Error>?
    var registrationRefreshTaskID: UUID?
    private var connectivityReconciliationOperation: ConnectivityReconciliationOperation?
    private var pendingConnectivityRevision: UInt64?
    var registrationRefreshPending = false
    var registrationRefreshPendingRequiresDiscovery = false
    var registrationRefreshEnabled = false
    var liveDiscoveryGeneration: UInt64 = 0
    var authoritativeDiscovery: CmxIrohDiscoveryResponse?
    var localBinding: CmxIrohBrokerBinding?
    var lastRegistrationRefreshState: CmxIrohRegistrationPublicationState?
    var registryContextProvider: CmxIrohRegistryContextProvider?
    var currentSnapshot = CmxIrohClientRuntimeSnapshot(
        state: .inactive,
        endpointID: nil,
        bindingID: nil
    )

    /// Creates an inactive iOS runtime and its stable deferred transport factory.
    ///
    /// The endpoint is not bound until ``start()``. The exposed
    /// ``transportFactory`` rejects dials until registration and discovery have
    /// installed one exact ``CmxIrohLocalBindingExpectation``.
    ///
    /// - Parameters:
    ///   - factory: The production Iroh binding or a test endpoint factory.
    ///   - broker: The authenticated registration, discovery, grant, and relay client.
    ///   - configuration: Stable account-and-build-scoped endpoint inputs.
    ///   - pendingRevocations: Device-only bindings that must be revoked before registration.
    ///   - protocolConfiguration: The cmux ALPN and stream framing configuration.
    ///   - diagnosticLog: Optional privacy-safe lifecycle sink for pooled sessions.
    ///   - networkPathSnapshot: A generation-aware view of positively identified
    ///     private-network profiles. An empty profile set disables explicit hints.
    ///   - now: Wall-clock injection for route and relay validation.
    ///   - handleBinding: Persists the exact verified binding and discovery state.
    ///   - handleRelayCredential: Persists an installed relay credential.
    ///   - handleLocalDeactivation: Wipes account-local Iroh caches during sign-out.
    ///   - handlePolicyInvalidation: Clears persisted broker routes after a terminal refresh.
    /// - Throws: An endpoint configuration error for an invalid cached relay set.
    public init(
        factory: any CmxIrohEndpointFactory,
        broker: any CmxIrohClientBrokerServing,
        configuration: CmxIrohClientRuntimeConfiguration,
        pendingRevocations: CmxIrohPendingRevocationOutbox,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        diagnosticLog: DiagnosticLog? = nil,
        offlinePolicyCache: CmxIrohClientOfflinePolicyCache? = nil,
        networkPathSnapshot: @escaping @Sendable () async throws -> CmxIrohNetworkPathSnapshot = {
            CmxIrohNetworkPathSnapshot(generation: 1, activeNetworkProfiles: [])
        },
        lanFallback: LANFallbackProvider? = nil,
        customPrivateFallback: CustomPrivateFallbackProvider? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        automaticRelayCredentialRefreshEnabled: Bool = true,
        handleBinding: @escaping BindingHandler = { _, _ in true },
        handleCachedBindings: @escaping CachedBindingsHandler = { _, _ in },
        handleRelayCredential: @escaping RelayCredentialHandler = { _, _ in },
        handleLocalDeactivation: @escaping LocalDeactivationHandler = {},
        handlePolicyInvalidation: @escaping PolicyInvalidationHandler = {}
    ) throws {
        let endpointRelayProfile = try configuration.resolvedEndpointRelayProfile(
            now: now()
        )
        let endpointConfiguration = CmxIrohEndpointConfiguration(
            secretKey: configuration.identity.secretKey,
            alpns: [protocolConfiguration.alpn],
            relayProfile: endpointRelayProfile
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration
        )
        let contextRouter = CmxIrohRuntimeContextRouter()
        let connectivityEngine = CmxConnectivityEngine(
            supervisor: supervisor,
            contextProvider: contextRouter,
            protocolConfiguration: protocolConfiguration,
            diagnosticLog: diagnosticLog,
            dialPhaseTimeout: configuration.dialPhaseTimeout
        )
        self.supervisor = supervisor
        self.connectivityEngine = connectivityEngine
        self.contextRouter = contextRouter
        self.broker = broker
        self.configuration = configuration
        self.endpointRelayProfile = endpointRelayProfile
        managedRelayURLs = configuration.managedRelayURLs
        self.pendingRevocations = pendingRevocations
        self.protocolConfiguration = protocolConfiguration
        self.offlinePolicyCache = offlinePolicyCache
        self.networkPathSnapshot = networkPathSnapshot
        self.lanFallback = lanFallback
        self.customPrivateFallback = customPrivateFallback
        self.diagnosticLog = diagnosticLog
        self.now = now
        self.automaticRelayCredentialRefreshEnabled = automaticRelayCredentialRefreshEnabled
        self.handleBinding = handleBinding
        self.handleCachedBindings = handleCachedBindings
        self.handleRelayCredential = handleRelayCredential
        self.handleLocalDeactivation = handleLocalDeactivation
        self.handlePolicyInvalidation = handlePolicyInvalidation
        transportFactory = CmxConnectivityByteTransportFactory(
            engine: connectivityEngine
        )
    }

    /// Returns the current non-secret lifecycle snapshot.
    public func snapshot() -> CmxIrohClientRuntimeSnapshot {
        currentSnapshot
    }

    /// Returns the non-secret hard expiry of the relay credential currently
    /// installed on the live endpoint.
    public func relayCredentialExpiresAt() async -> Date? {
        await relayCoordinator?.credentialExpiresAt()
    }

    /// Monotonic count of online broker snapshots verified by this runtime.
    public func liveDiscoverySnapshotGeneration() -> UInt64 {
        liveDiscoveryGeneration
    }

    /// Refreshes registration and discovery, returning true only when a new
    /// online broker snapshot was verified and installed.
    ///
    /// Connectivity fallback may preserve an existing verified runtime for
    /// already-paired Macs, but returns false here so a cached or stale snapshot
    /// can never authorize a first pairing.
    public func refreshLiveDiscovery() async -> Bool {
        await refreshLiveDiscoveryOutcome() == .refreshed
    }

    /// Refreshes registration and discovery with a privacy-safe failure reason.
    ///
    /// Connectivity fallback may preserve the existing verified runtime, but
    /// returns a categorical failure so diagnostics can distinguish an offline
    /// broker, unavailable policy, inactive endpoint, and superseded lifecycle.
    /// Raw errors and their potentially sensitive associated data are discarded.
    ///
    /// - Returns: Whether a new verified snapshot was installed, or the bounded
    ///   reason it was not.
    public func refreshLiveDiscoveryOutcome() async -> CmxIrohLiveDiscoveryRefreshOutcome {
        do {
            return try await refreshLiveDiscoveryOutcomeThrowing()
        } catch {
            return .failed(DiagnosticFailureKind.classify(error))
        }
    }

    /// Reconciles a pushed account route revision without re-registering the
    /// local endpoint.
    ///
    /// The push frame is only a hint. This method fetches the complete
    /// connectivity-v2 snapshot, validates that the active local binding is
    /// still present, atomically replaces admission policy, persists the same
    /// snapshot used by dials, and only then retires sessions from the prior
    /// revision. Concurrent invalidations share one operation.
    public func reconcileConnectivityRevision(
        _ hintedRevision: UInt64
    ) async -> CmxIrohLiveDiscoveryRefreshOutcome {
        guard lifecyclePhase == .active else {
            return .failed(.endpointUnavailable)
        }
        pendingConnectivityRevision = max(
            pendingConnectivityRevision ?? hintedRevision,
            hintedRevision
        )

        while lifecyclePhase == .active {
            let installed = await connectivityEngine.snapshot().routeRevision
            if let installed,
               installed >= hintedRevision,
               pendingConnectivityRevision.map({ $0 <= installed }) ?? true {
                return .refreshed
            }

            let operation: ConnectivityReconciliationOperation
            if let connectivityReconciliationOperation {
                operation = connectivityReconciliationOperation
            } else {
                let targetRevision = max(
                    pendingConnectivityRevision ?? hintedRevision,
                    hintedRevision
                )
                pendingConnectivityRevision = nil
                let id = UUID()
                let task = Task<CmxIrohLiveDiscoveryRefreshOutcome, Never> { [weak self] in
                    guard let self else {
                        return .failed(.endpointUnavailable)
                    }
                    return await self.performConnectivityReconciliation(
                        hintedRevision: targetRevision
                    )
                }
                operation = ConnectivityReconciliationOperation(id: id, task: task)
                connectivityReconciliationOperation = operation
            }
            let outcome = await operation.task.value
            if connectivityReconciliationOperation?.id == operation.id {
                connectivityReconciliationOperation = nil
            }
            guard outcome == .refreshed else {
                return outcome
            }
        }
        return .failed(.endpointUnavailable)
    }

    private func performConnectivityReconciliation(
        hintedRevision: UInt64
    ) async -> CmxIrohLiveDiscoveryRefreshOutcome {
        let revision = lifecycleRevision
        do {
            if let refresh = registrationRefreshTask {
                _ = try await refresh.value
                try requireCurrent(revision)
                if let installed = await connectivityEngine.snapshot().routeRevision,
                   installed >= hintedRevision {
                    return .refreshed
                }
            }
            guard let localBinding else {
                return .failed(.endpointUnavailable)
            }
            let liveEndpointIdentity = try await connectivityEngine
                .localEndpointIdentity()
            guard localBinding.endpointID == liveEndpointIdentity else {
                throw CmxIrohClientRuntimeError.invalidLocalBinding
            }
            let expectation = try CmxIrohLocalBindingExpectation(
                deviceID: configuration.deviceID,
                appInstanceID: configuration.appInstanceID,
                clientNamespace: configuration.clientNamespace,
                tag: configuration.tag,
                platform: .ios,
                endpointID: liveEndpointIdentity,
                identityGeneration: configuration.identity.generation,
                pairingEnabled: false,
                capabilities: configuration.capabilities
            )
            let discovery = try await discoverAuthoritatively()
            try requireCurrent(revision)
            guard self.localBinding?.bindingID == localBinding.bindingID,
                  self.localBinding?.endpointID == liveEndpointIdentity else {
                throw CmxIrohClientRuntimeError.invalidLocalBinding
            }
            guard let discoveredRevision = discovery.revision,
                  discoveredRevision >= hintedRevision else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            guard discovery.routeContractVersion
                    == CmxIrohRegistrationPayload.currentRouteContractVersion else {
                throw CmxIrohClientRuntimeError.routeContractMismatch
            }
            try validateRelayFleet(discovery.relayFleet)
            let matches = discovery.bindings.filter(expectation.matches)
            guard matches.count == 1, let discoveredBinding = matches.first else {
                throw CmxIrohClientRuntimeError.localBindingMissingFromDiscovery
            }
            let offlineExpectation: CmxIrohClientOfflinePolicyExpectation? =
                try offlinePolicyCache.flatMap { _ in
                    guard !managedRelayURLs.isEmpty else { return nil }
                    return try CmxIrohClientOfflinePolicyExpectation(
                        accountID: configuration.accountID,
                        localBindingExpectation: expectation,
                        managedRelayURLs: managedRelayURLs
                    )
                }
            try await install(
                policy: ResolvedPolicy(
                    registration: nil,
                    discovery: discovery,
                    binding: discoveredBinding,
                    expectation: expectation,
                    offlineExpectation: offlineExpectation,
                    cachedTargetBindings: [],
                    cachedLANRendezvous: nil
                ),
                revision: revision,
                startRelays: false
            )
            try requireCurrent(revision)
            let published = await handleBinding(discoveredBinding, discovery)
            try requireCurrent(revision)
            guard published else {
                return .failed(.superseded)
            }
            await connectivityEngine.didInstallRouteRevision(
                discoveredRevision,
                routes: discovery
            )
            liveDiscoveryGeneration &+= 1
            return .refreshed
        } catch {
            return .failed(DiagnosticFailureKind.classify(error))
        }
    }

    func refreshLiveDiscoveryThrowing() async throws -> Bool {
        try await refreshLiveDiscoveryOutcomeThrowing() == .refreshed
    }

    private func refreshLiveDiscoveryOutcomeThrowing() async throws
        -> CmxIrohLiveDiscoveryRefreshOutcome
    {
        guard lifecyclePhase == .active else {
            return .failed(.endpointUnavailable)
        }
        let priorGeneration = liveDiscoveryGeneration
        var mayScheduleFreshRequest = registrationRefreshTask != nil
        var latestOutcome: CmxIrohLiveDiscoveryRefreshOutcome = .failed(.superseded)
        if registrationRefreshTask == nil {
            scheduleRegistrationRefresh(
                revision: lifecycleRevision,
                requiresDiscovery: true
            )
        }
        var lastAwaitedTaskID: UUID?
        while lifecyclePhase == .active,
              let refresh = registrationRefreshTask,
              let refreshID = registrationRefreshTaskID,
              refreshID != lastAwaitedTaskID {
            lastAwaitedTaskID = refreshID
            let outcome = try await refresh.value
            guard lifecyclePhase == .active else {
                return .failed(.endpointUnavailable)
            }
            if liveDiscoveryGeneration > priorGeneration { return .refreshed }
            // A `.refreshed` outcome without a generation advance is an
            // unchanged-fingerprint no-op that never read the broker. It can
            // neither satisfy this live discovery nor mask a real failure,
            // and a coalesced successor may no-op the same way, so the right
            // to schedule one authoritative refresh must survive successors.
            if outcome != .refreshed { latestOutcome = outcome }
            if registrationRefreshTaskID != nil { continue }
            guard mayScheduleFreshRequest else { return latestOutcome }
            mayScheduleFreshRequest = false
            scheduleRegistrationRefresh(
                revision: lifecycleRevision,
                requiresDiscovery: true
            )
        }
        return lifecyclePhase == .active
            ? latestOutcome
            : .failed(.endpointUnavailable)
    }

    /// Returns the selected live path after removing raw transport coordinates.
    ///
    /// Relay attribution succeeds only when the selected relay is present in
    /// the exact verified effective policy installed by the composition root.
    ///
    /// - Parameter relayPolicy: The current verified effective relay policy.
    /// - Returns: A credential-free path category safe for settings and diagnostics.
    public func selectedTransportPath(
        relayPolicy: CmxIrohEffectiveRelayPolicy?
    ) async -> CmxIrohSelectedTransportPath {
        return await connectivityEngine.selectedTransportPath(
            relayPolicy: relayPolicy
        )
    }

    /// Emits when connection lifecycle changes may alter the selected path.
    ///
    /// Consumers re-read ``selectedTransportPath(relayPolicy:)`` for the
    /// credential-free value. The stream never carries raw path data.
    public func selectedTransportPathChanges() async -> AsyncStream<Void> {
        await connectivityEngine.selectedTransportPathChanges()
    }

    /// Binds the endpoint, registers it, and installs exact discovery and relay policy.
    ///
    /// - Throws: A bind, broker, signature, fleet, or local-binding validation error.
    public func start() async throws {
        guard lifecyclePhase.allowsStart else {
            throw CmxIrohClientRuntimeError.alreadyActive
        }
        lifecyclePhase = .starting
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        registrationRefreshPending = false
        registrationRefreshPendingRequiresDiscovery = false
        registrationRefreshEnabled = false
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .starting,
            endpointID: nil,
            bindingID: nil
        )

        do {
            let startingRelayProfile = try endpointRelayProfile
                .droppingExpiredManagedCredentials(at: now())
            if startingRelayProfile != endpointRelayProfile {
                try await connectivityEngine.replaceRelayProfile(
                    startingRelayProfile
                )
                endpointRelayProfile = startingRelayProfile
            }
            await startSupervisorObservation(revision: revision)
            let cachedDiscoveryTask: Task<CmxIrohDiscoveryResponse?, Never>?
            if configuration.cachedBinding != nil {
                try await preparePolicyResolution(revision: revision)
                cachedDiscoveryTask = Task { [weak self] in
                    guard let self else { return nil }
                    return try? await self.prefetchAuthoritativeDiscovery()
                }
            } else {
                cachedDiscoveryTask = nil
            }
            defer { cachedDiscoveryTask?.cancel() }
            try await connectivityEngine.start()
            let endpointSnapshot = await connectivityEngine.snapshot()
            try requireCurrent(revision)
            guard let endpointID = endpointSnapshot.localIdentity,
                  endpointSnapshot.endpointGeneration != nil else {
                throw CmxIrohClientRuntimeError.invalidLocalBinding
            }
            let policy = try await resolvePolicy(
                expectedEndpointID: endpointID,
                revision: revision,
                prefetchedDiscovery: await cachedDiscoveryTask?.value,
                brokerPreparationComplete: cachedDiscoveryTask != nil
            )
            try requireCurrent(revision)
            try await install(policy: policy, revision: revision, startRelays: true)
            if !protocolConfiguration.allowsNATTraversalAfterAdmission {
                guard await connectivityEngine.hasConfiguredRelay() else {
                    throw CmxIrohEndpointSupervisorError.relayReadinessTimedOut
                }
                try await connectivityEngine.waitForUsableHomeRelay()
                try requireCurrent(revision)
            }
            lifecyclePhase = .active
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            if let discovery = policy.discovery {
                let published = await handleBinding(policy.binding, discovery)
                try requireCurrent(revision)
                if published {
                    if let routeRevision = discovery.revision {
                        await connectivityEngine.didInstallRouteRevision(
                            routeRevision,
                            routes: discovery
                        )
                    }
                    liveDiscoveryGeneration &+= 1
                }
            } else if let lanRendezvous = policy.cachedLANRendezvous {
                await handleCachedBindings(policy.cachedTargetBindings, lanRendezvous)
            }
            if policy.registration == nil, policy.discovery != nil {
                registrationRefreshPending = true
            }
            registrationRefreshEnabled = true
            if registrationRefreshPending {
                registrationRefreshPending = false
                scheduleRegistrationRefresh(revision: revision)
            }
        } catch {
            guard lifecyclePhase == .starting,
                  lifecycleRevision == revision else {
                throw error
            }
            lifecyclePhase = .stopping
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .failed,
                endpointID: nil,
                bindingID: localBinding?.bindingID
            )
            await tearDownNetwork()
            if lifecyclePhase == .stopping,
               lifecycleRevision == revision {
                lifecyclePhase = .failed
            }
            throw error
        }
    }

    /// Records a background transition without closing the endpoint or streams.
    ///
    /// iOS may suspend the process immediately, so the runtime deliberately
    /// performs no network or persistence work on this transition.
    public func didEnterBackground() {
        // Endpoint ownership is process-scoped and survives ordinary suspension.
    }

    /// Health-checks the preserved endpoint and refreshes its signed registration.
    ///
    /// A healthy generation is reused. A stale driver is recreated with the
    /// same secret key before registration is refreshed.
    ///
    /// - Throws: A replacement-bind or terminal policy-refresh error. Connectivity
    ///   failure keeps the last verified local policy for a later retry.
    public func didBecomeActive() async throws {
        guard lifecyclePhase == .active else { return }
        let revision = lifecycleRevision
        // A registration refresh reads the active endpoint. Keep the preserved
        // generation installed until any existing refresh finishes, then pause
        // new refreshes across the brief unbound window used for stale-driver
        // replacement. Supervisor events become one pending refresh that the
        // explicit foreground refresh below consumes.
        registrationRefreshEnabled = false
        do {
            if let refresh = registrationRefreshTask {
                _ = try await refresh.value
                try requireCurrent(revision)
            }
            try await connectivityEngine.resume()
            let checked = await connectivityEngine.snapshot()
            try requireCurrent(revision)
            guard checked.endpointGeneration != nil else {
                throw CmxIrohClientRuntimeError.invalidLocalBinding
            }
            try requireCurrent(revision)
            registrationRefreshPending = false
            registrationRefreshPendingRequiresDiscovery = false
            registrationRefreshEnabled = true
            _ = try await refreshLiveDiscoveryThrowing()
            try requireCurrent(revision)
            try await relayCoordinator?.refreshIfNeeded()
            try requireCurrent(revision)
        } catch {
            if lifecyclePhase == .active, lifecycleRevision == revision {
                registrationRefreshEnabled = true
            }
            throw error
        }
    }

    /// Opens a terminal or artifact lane on the admitted pooled peer connection.
    ///
    /// The same session also carries the existing RPC control lane, avoiding a
    /// second QUIC handshake and preserving Iroh stream prioritization.
    ///
    /// - Parameters:
    ///   - request: The exact Iroh route and intended Mac device binding.
    ///   - lane: A terminal or artifact lane declaration.
    ///   - priority: Iroh's relative stream priority.
    /// - Returns: The stream after its authenticated lane header is written.
    /// - Throws: A lifecycle, discovery, admission, or stream-framing error.
    public func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        guard lifecyclePhase == .active else {
            throw CmxIrohClientRuntimeError.inactive
        }
        return try await connectivityEngine.openBidirectionalLane(
            for: request,
            lane: lane,
            priority: priority
        )
    }

    /// Starts the one client-owned server-event accept loop for this peer.
    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        guard lifecyclePhase == .active else {
            throw CmxIrohClientRuntimeError.inactive
        }
        return try await connectivityEngine.serverEventByteStream(for: request)
    }

    /// Invalidates one peer session after a lane reports a terminal connection error.
    ///
    /// The next control or lane operation performs fresh discovery and admission.
    ///
    /// - Parameter request: The exact peer intent whose pooled connection failed.
    public func invalidateSession(for request: CmxByteTransportRequest) async {
        await connectivityEngine.invalidatePeer(for: request)
    }

    /// Invalidates reusable broker discovery state for one Mac device.
    ///
    /// Called when a presence route push proves the Mac's endpoint
    /// re-registered: any snapshot captured before the push is corpse data,
    /// so the next dial to that Mac fetches a fresh discovery snapshot
    /// (single-flight, bounded by the broker backpressure gate) instead of
    /// reusing it.
    ///
    /// - Parameter deviceID: The Mac's registry device id, or `nil` to
    ///   invalidate discovery reuse for every peer.
    public func invalidateDiscoverySnapshot(forMacDeviceID deviceID: String?) async {
        await registryContextProvider?.invalidateVerifiedDiscovery(
            forDeviceID: deviceID
        )
    }

    /// Stops network ownership while preserving account-scoped persistence.
    public func stop() async {
        guard lifecyclePhase == .starting || lifecyclePhase == .active else {
            return
        }
        lifecyclePhase = .stopping
        lifecycleRevision &+= 1
        connectivityReconciliationOperation?.task.cancel()
        connectivityReconciliationOperation = nil
        pendingConnectivityRevision = nil
        let revision = lifecycleRevision
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .stopping,
            endpointID: currentSnapshot.endpointID,
            bindingID: localBinding?.bindingID
        )
        await tearDownNetwork()
        guard lifecyclePhase == .stopping,
              lifecycleRevision == revision else { return }
        lifecyclePhase = .inactive
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .inactive,
            endpointID: nil,
            bindingID: nil
        )
    }

    /// Closes networking, durably queues revocation, then deactivates local state.
    ///
    /// The binding is captured and the lifecycle enters `signingOut` before the
    /// first suspension. Endpoint teardown and device-only persistence run
    /// concurrently. Persistence failure leaves the closed runtime quarantined,
    /// retains the binding, and skips every local identity deactivation hook.
    /// Calling this method again while quarantined retries the durable enqueue.
    ///
    /// - Returns: The prior binding and whether it was durably queued.
    public func deactivateForSignOut() async -> CmxIrohClientSignOutPreparation {
        if let signOutOperation {
            return await signOutOperation.value
        }
        let pendingRevocation = localBinding.flatMap { binding in
            try? CmxIrohPendingRevocation(
                accountID: configuration.accountID,
                tag: configuration.tag,
                bindingID: binding.bindingID
            )
        }
        let bindingAuthorization = localBinding.flatMap { binding in
            try? CmxIrohBindingRequestAuthorization(
                bindingID: binding.bindingID,
                clientNamespace: binding.clientNamespace,
                identity: configuration.identity,
                endpointID: binding.endpointID
            )
        }
        lifecyclePhase = .signingOut
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .signingOut,
            endpointID: currentSnapshot.endpointID,
            bindingID: pendingRevocation?.bindingID
        )

        let operation = Task {
            await self.performSignOut(
                pendingRevocation: pendingRevocation,
                bindingAuthorization: bindingAuthorization,
                revision: revision
            )
        }
        signOutOperation = operation
        return await operation.value
    }

}
