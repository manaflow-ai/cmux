public import CMUXMobileCore
public import Foundation

/// Owns one account-and-build-scoped iOS endpoint and its verified broker policy.
public actor CmxIrohClientRuntime {
    /// Runs after a registration and exact discovery response have been verified.
    public typealias BindingHandler = @Sendable (
        _ registration: CmxIrohRegistrationResponse,
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
    public nonisolated let transportFactory: CmxIrohByteTransportFactory

    let supervisor: CmxIrohEndpointSupervisor
    let contextRouter: CmxIrohRuntimeContextRouter
    let sessionPool: CmxIrohClientSessionPool
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
    var registrationRefreshPending = false
    var registrationRefreshEnabled = false
    var liveDiscoveryGeneration: UInt64 = 0
    var localBinding: CmxIrohBrokerBinding?
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
        let sessionPool = CmxIrohClientSessionPool(
            supervisor: supervisor,
            contextProvider: contextRouter,
            protocolConfiguration: protocolConfiguration,
            diagnosticLog: diagnosticLog
        )
        self.supervisor = supervisor
        self.contextRouter = contextRouter
        self.sessionPool = sessionPool
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
        self.now = now
        self.automaticRelayCredentialRefreshEnabled = automaticRelayCredentialRefreshEnabled
        self.handleBinding = handleBinding
        self.handleCachedBindings = handleCachedBindings
        self.handleRelayCredential = handleRelayCredential
        self.handleLocalDeactivation = handleLocalDeactivation
        self.handlePolicyInvalidation = handlePolicyInvalidation
        transportFactory = CmxIrohByteTransportFactory(sessionPool: sessionPool)
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
            scheduleRegistrationRefresh(revision: lifecycleRevision)
        }
        var lastAwaitedTaskID: UUID?
        while lifecyclePhase == .active,
              let refresh = registrationRefreshTask,
              let refreshID = registrationRefreshTaskID,
              refreshID != lastAwaitedTaskID {
            lastAwaitedTaskID = refreshID
            latestOutcome = try await refresh.value
            guard lifecyclePhase == .active else {
                return .failed(.endpointUnavailable)
            }
            if liveDiscoveryGeneration > priorGeneration { return .refreshed }
            if registrationRefreshTaskID != nil {
                mayScheduleFreshRequest = false
                continue
            }
            guard mayScheduleFreshRequest else { return latestOutcome }
            mayScheduleFreshRequest = false
            scheduleRegistrationRefresh(revision: lifecycleRevision)
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
        let observed = await sessionPool.selectedObservedPath()
        return CmxIrohSelectedTransportPathClassifier(policy: relayPolicy)
            .classify(observed)
    }

    /// Emits when connection lifecycle changes may alter the selected path.
    ///
    /// Consumers re-read ``selectedTransportPath(relayPolicy:)`` for the
    /// credential-free value. The stream never carries raw path data.
    public func selectedTransportPathChanges() async -> AsyncStream<Void> {
        await sessionPool.selectedPathChanges()
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
                try await supervisor.replaceRelayProfile(startingRelayProfile)
                endpointRelayProfile = startingRelayProfile
            }
            await startSupervisorObservation(revision: revision)
            let endpointSnapshot = try await supervisor.activate()
            try requireCurrent(revision)
            guard let endpointID = endpointSnapshot.identity else {
                throw CmxIrohClientRuntimeError.invalidLocalBinding
            }
            let policy = try await resolvePolicy(
                expectedEndpointID: endpointID,
                revision: revision
            )
            try requireCurrent(revision)
            await sessionPool.activate(
                runtimeGeneration: endpointSnapshot.runtimeGeneration
            )
            try await install(policy: policy, revision: revision, startRelays: true)
            if !protocolConfiguration.allowsNATTraversalAfterAdmission {
                guard await supervisor.hasConfiguredRelay() else {
                    throw CmxIrohEndpointSupervisorError.relayReadinessTimedOut
                }
                try await supervisor.waitForUsableHomeRelay()
                try requireCurrent(revision)
            }
            lifecyclePhase = .active
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            if let registration = policy.registration,
               let discovery = policy.discovery {
                let published = await handleBinding(registration, discovery)
                try requireCurrent(revision)
                if published { liveDiscoveryGeneration &+= 1 }
            } else if let lanRendezvous = policy.cachedLANRendezvous {
                await handleCachedBindings(policy.cachedTargetBindings, lanRendezvous)
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
            let checked = try await supervisor.ensureHealthy()
            try requireCurrent(revision)
            await sessionPool.activate(runtimeGeneration: checked.runtimeGeneration)
            try requireCurrent(revision)
            registrationRefreshPending = false
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
        return try await sessionPool.openBidirectionalLane(
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
        return try await sessionPool.serverEventByteStream(for: request)
    }

    /// Invalidates one peer session after a lane reports a terminal connection error.
    ///
    /// The next control or lane operation performs fresh discovery and admission.
    ///
    /// - Parameter request: The exact peer intent whose pooled connection failed.
    public func invalidateSession(for request: CmxByteTransportRequest) async {
        await sessionPool.invalidate(for: request)
    }

    /// Stops network ownership while preserving account-scoped persistence.
    public func stop() async {
        guard lifecyclePhase == .starting || lifecyclePhase == .active else {
            return
        }
        lifecyclePhase = .stopping
        lifecycleRevision &+= 1
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
                revision: revision
            )
        }
        signOutOperation = operation
        return await operation.value
    }

}
