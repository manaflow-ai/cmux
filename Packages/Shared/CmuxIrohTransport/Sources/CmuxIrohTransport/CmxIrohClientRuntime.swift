public import CMUXMobileCore
public import Foundation

/// Owns one account-and-build-scoped iOS endpoint and its verified broker policy.
public actor CmxIrohClientRuntime {
    /// Runs after a registration and exact discovery response have been verified.
    public typealias BindingHandler = @Sendable (
        _ registration: CmxIrohRegistrationResponse,
        _ discovery: CmxIrohDiscoveryResponse
    ) async -> Void

    /// Runs when connectivity-only startup restores signed, already-known Mac tuples.
    public typealias CachedBindingsHandler = @Sendable (
        _ bindings: [CmxIrohBrokerBinding],
        _ lanRendezvous: CmxIrohLANRendezvous
    ) async -> Void

    /// Supplies local-link reachability only for one authenticated Mac tuple.
    public typealias LANFallbackProvider = CmxIrohRegistryContextProvider.LANFallbackProvider

    /// Runs after a relay credential is installed on the exact active binding.
    public typealias RelayCredentialHandler = @Sendable (
        _ response: CmxIrohRelayTokenResponse,
        _ binding: CmxIrohBrokerBinding
    ) async -> Void

    /// Removes account-local identity, binding, relay, and route cache state.
    public typealias LocalDeactivationHandler = @Sendable () async -> Void

    /// Removes persisted binding and route state after terminal broker evidence.
    public typealias PolicyInvalidationHandler = @Sendable () async -> Void

    private struct ResolvedPolicy: Sendable {
        let registration: CmxIrohRegistrationResponse?
        let discovery: CmxIrohDiscoveryResponse?
        let binding: CmxIrohBrokerBinding
        let expectation: CmxIrohLocalBindingExpectation
        let offlineExpectation: CmxIrohClientOfflinePolicyExpectation?
        let cachedTargetBindings: [CmxIrohBrokerBinding]
        let cachedLANRendezvous: CmxIrohLANRendezvous?
    }

    /// The route-aware factory registered by the iOS app before fallback transports.
    public nonisolated let transportFactory: CmxIrohByteTransportFactory

    private let supervisor: CmxIrohEndpointSupervisor
    private let contextRouter: CmxIrohRuntimeContextRouter
    private let sessionPool: CmxIrohClientSessionPool
    private let broker: any CmxIrohClientBrokerServing
    private let configuration: CmxIrohClientRuntimeConfiguration
    private let pendingRevocations: CmxIrohPendingRevocationOutbox
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let offlinePolicyCache: CmxIrohClientOfflinePolicyCache?
    private let networkPathSnapshot: @Sendable () async throws -> CmxIrohNetworkPathSnapshot
    private let lanFallback: LANFallbackProvider?
    private let now: @Sendable () -> Date
    private let handleBinding: BindingHandler
    private let handleCachedBindings: CachedBindingsHandler
    private let handleRelayCredential: RelayCredentialHandler
    private let handleLocalDeactivation: LocalDeactivationHandler
    private let handlePolicyInvalidation: PolicyInvalidationHandler

    private var lifecycleRevision: UInt64 = 0
    private var desiredActive = false
    private var relayCoordinator: CmxIrohRelayCredentialCoordinator?
    private var supervisorEventTask: Task<Void, Never>?
    private var registrationRefreshTask: Task<Void, Never>?
    private var localBinding: CmxIrohBrokerBinding?
    private var currentSnapshot = CmxIrohClientRuntimeSnapshot(
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
        offlinePolicyCache: CmxIrohClientOfflinePolicyCache? = nil,
        networkPathSnapshot: @escaping @Sendable () async throws -> CmxIrohNetworkPathSnapshot = {
            CmxIrohNetworkPathSnapshot(generation: 1, activeNetworkProfiles: [])
        },
        lanFallback: LANFallbackProvider? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        handleBinding: @escaping BindingHandler = { _, _ in },
        handleCachedBindings: @escaping CachedBindingsHandler = { _, _ in },
        handleRelayCredential: @escaping RelayCredentialHandler = { _, _ in },
        handleLocalDeactivation: @escaping LocalDeactivationHandler = {},
        handlePolicyInvalidation: @escaping PolicyInvalidationHandler = {}
    ) throws {
        let cachedRelays = Self.cachedRelayConfigurations(
            configuration: configuration,
            now: now()
        )
        let endpointConfiguration = try CmxIrohEndpointConfiguration(
            secretKey: configuration.identity.secretKey,
            alpns: [protocolConfiguration.alpn],
            managedRelayURLs: configuration.managedRelayURLs,
            relays: cachedRelays
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration
        )
        let contextRouter = CmxIrohRuntimeContextRouter()
        let sessionPool = CmxIrohClientSessionPool(
            supervisor: supervisor,
            contextProvider: contextRouter,
            protocolConfiguration: protocolConfiguration
        )
        self.supervisor = supervisor
        self.contextRouter = contextRouter
        self.sessionPool = sessionPool
        self.broker = broker
        self.configuration = configuration
        self.pendingRevocations = pendingRevocations
        self.protocolConfiguration = protocolConfiguration
        self.offlinePolicyCache = offlinePolicyCache
        self.networkPathSnapshot = networkPathSnapshot
        self.lanFallback = lanFallback
        self.now = now
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

    /// Binds the endpoint, registers it, and installs exact discovery and relay policy.
    ///
    /// - Throws: A bind, broker, signature, fleet, or local-binding validation error.
    public func start() async throws {
        guard !desiredActive else {
            throw CmxIrohClientRuntimeError.alreadyActive
        }
        desiredActive = true
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .starting,
            endpointID: nil,
            bindingID: nil
        )

        do {
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
            startSupervisorObservation(revision: revision)
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            if let registration = policy.registration,
               let discovery = policy.discovery {
                await handleBinding(registration, discovery)
            } else if let lanRendezvous = policy.cachedLANRendezvous {
                await handleCachedBindings(policy.cachedTargetBindings, lanRendezvous)
            }
        } catch {
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .failed,
                endpointID: nil,
                bindingID: localBinding?.bindingID
            )
            await tearDownNetwork()
            desiredActive = false
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
        guard desiredActive else { return }
        let revision = lifecycleRevision
        let checked = try await supervisor.ensureHealthy()
        try requireCurrent(revision)
        await sessionPool.activate(runtimeGeneration: checked.runtimeGeneration)
        try await refreshRegistration(revision: revision)
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
        guard desiredActive else { throw CmxIrohClientRuntimeError.inactive }
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
        guard desiredActive else { throw CmxIrohClientRuntimeError.inactive }
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
        guard desiredActive else { return }
        desiredActive = false
        lifecycleRevision &+= 1
        await tearDownNetwork()
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .inactive,
            endpointID: nil,
            bindingID: nil
        )
    }

    /// Performs local-first sign-out teardown and captures the binding to revoke.
    ///
    /// The endpoint, route context, and relay scheduler are stopped before the
    /// injected cache wipe runs. Remote revocation is intentionally separate so
    /// the auth layer can supply tokens captured before its own local clear.
    ///
    /// - Returns: The prior binding identifier for best-effort broker revocation.
    public func deactivateForSignOut() async -> CmxIrohClientSignOutPreparation {
        let pendingRevocation = localBinding.flatMap { binding in
            try? CmxIrohPendingRevocation(
                accountID: configuration.accountID,
                tag: configuration.tag,
                bindingID: binding.bindingID
            )
        }
        var wasPersisted = pendingRevocation == nil
        if let pendingRevocation {
            do {
                try await pendingRevocations.enqueue(pendingRevocation)
                wasPersisted = true
            } catch {
                // Local identity teardown must not wait on Keychain recovery.
                // The returned preparation retries this enqueue before DELETE.
            }
        }
        let preparation = CmxIrohClientSignOutPreparation(
            pendingRevocation: pendingRevocation,
            wasPersisted: wasPersisted
        )
        desiredActive = false
        lifecycleRevision &+= 1
        await tearDownNetwork()
        try? await offlinePolicyCache?.deactivate()
        await handleLocalDeactivation()
        currentSnapshot = CmxIrohClientRuntimeSnapshot(
            state: .inactive,
            endpointID: nil,
            bindingID: nil
        )
        return preparation
    }

    private func resolvePolicy(
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64
    ) async throws -> ResolvedPolicy {
        try await pendingRevocations.revokePending(
            accountID: configuration.accountID,
            beforeRegisteringTag: configuration.tag,
            using: broker
        )
        try requireCurrent(revision)
        let endpoint = try await supervisor.activeEndpoint()
        let address = await endpoint.address()
        guard address.identity == expectedEndpointID else {
            throw CmxIrohClientRuntimeError.invalidLocalBinding
        }
        let publicHints = Array(address.pathHints.compactMap {
            $0.publicDisclosure(at: now())
        }.prefix(CmxAttachEndpoint.maximumIrohPathHintCount))
        let payload = try CmxIrohRegistrationPayload(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            tag: configuration.tag,
            platform: .ios,
            displayName: configuration.displayName,
            endpointID: expectedEndpointID.endpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: false,
            capabilities: configuration.capabilities,
            pathHints: publicHints,
            now: now()
        )
        let expectation = try CmxIrohLocalBindingExpectation(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            tag: configuration.tag,
            platform: .ios,
            endpointID: expectedEndpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: false,
            capabilities: configuration.capabilities
        )
        let offlineExpectation = try offlinePolicyCache.map { _ in
            try CmxIrohClientOfflinePolicyExpectation(
                accountID: configuration.accountID,
                localBindingExpectation: expectation,
                managedRelayURLs: configuration.managedRelayURLs
            )
        }
        let signer = try CmxIrohRegistrationSigner(
            identity: configuration.identity,
            endpointID: expectedEndpointID.endpointID
        )
        let prepared = try signer.prepare(payload: payload)
        let registration: CmxIrohRegistrationResponse
        do {
            registration = try await broker.register(prepared: prepared, signer: signer)
        } catch {
            guard Self.isConnectivity(error),
                  let cached = try await offlineBootstrap(
                      expectation: offlineExpectation,
                      confirmedLocalBinding: nil
                  ) else {
                throw error
            }
            return ResolvedPolicy(
                registration: nil,
                discovery: nil,
                binding: cached.localBinding,
                expectation: expectation,
                offlineExpectation: offlineExpectation,
                cachedTargetBindings: cached.targetBindings,
                cachedLANRendezvous: cached.lanRendezvous
            )
        }
        try requireCurrent(revision)
        guard expectation.matches(registration.binding) else {
            throw CmxIrohClientRuntimeError.invalidLocalBinding
        }
        if case let .issued(relay) = registration.relay {
            try validateRelayFleet(relay.relayFleet)
        }

        let discovery: CmxIrohDiscoveryResponse
        do {
            discovery = try await broker.discover()
        } catch {
            guard Self.isConnectivity(error),
                  let cached = try await offlineBootstrap(
                      expectation: offlineExpectation,
                      confirmedLocalBinding: registration.binding
                  ) else {
                throw error
            }
            return ResolvedPolicy(
                registration: registration,
                discovery: nil,
                binding: cached.localBinding,
                expectation: expectation,
                offlineExpectation: offlineExpectation,
                cachedTargetBindings: cached.targetBindings,
                cachedLANRendezvous: cached.lanRendezvous
            )
        }
        try requireCurrent(revision)
        guard discovery.routeContractVersion == payload.routeContractVersion else {
            throw CmxIrohClientRuntimeError.routeContractMismatch
        }
        try validateRelayFleet(discovery.relayFleet)
        let localMatches = discovery.bindings.filter(expectation.matches)
        guard localMatches.count == 1,
              let discovered = localMatches.first,
              discovered.bindingID == registration.binding.bindingID else {
            throw CmxIrohClientRuntimeError.localBindingMissingFromDiscovery
        }
        return ResolvedPolicy(
            registration: registration,
            discovery: discovery,
            binding: discovered,
            expectation: expectation,
            offlineExpectation: offlineExpectation,
            cachedTargetBindings: [],
            cachedLANRendezvous: nil
        )
    }

    private func offlineBootstrap(
        expectation: CmxIrohClientOfflinePolicyExpectation?,
        confirmedLocalBinding: CmxIrohBrokerBinding?
    ) async throws -> CmxIrohClientOfflineBootstrap? {
        guard let offlinePolicyCache, let expectation else { return nil }
        return try await offlinePolicyCache.loadBootstrap(
            for: expectation,
            confirmedLocalBinding: confirmedLocalBinding,
            now: now()
        )
    }

    private func install(
        policy: ResolvedPolicy,
        revision: UInt64,
        startRelays: Bool
    ) async throws {
        try requireCurrent(revision)
        let offlinePolicy = try policy.offlineExpectation.map { expectation in
            guard let offlinePolicyCache else {
                throw CmxIrohClientOfflinePolicyCacheError.policyMismatch
            }
            return try CmxIrohClientOfflinePolicyContext(
                cache: offlinePolicyCache,
                expectation: expectation,
                localBinding: policy.binding
            )
        }
        let provider = CmxIrohRegistryContextProvider(
            supervisor: supervisor,
            broker: broker,
            localBindingExpectation: policy.expectation,
            managedRelayURLs: configuration.managedRelayURLs,
            networkPathSnapshot: networkPathSnapshot,
            offlinePolicy: offlinePolicy,
            lanFallback: lanFallback,
            now: now
        )
        await contextRouter.install(provider)
        localBinding = policy.binding

        let coordinator: CmxIrohRelayCredentialCoordinator
        if let relayCoordinator {
            coordinator = relayCoordinator
        } else {
            coordinator = CmxIrohRelayCredentialCoordinator(
                supervisor: supervisor,
                broker: broker,
                managedRelayURLs: configuration.managedRelayURLs,
                credentialDidInstall: { [handleRelayCredential] response in
                    await handleRelayCredential(response, policy.binding)
                }
            )
            relayCoordinator = coordinator
        }

        let bootstrap: CmxIrohRelayTokenResponse?
        if let registration = policy.registration {
            switch registration.relay {
            case let .issued(response):
                bootstrap = response
            case .unavailable:
                bootstrap = startRelays ? configuration.cachedRelayCredential : nil
            }
        } else {
            bootstrap = startRelays ? configuration.cachedRelayCredential : nil
        }
        if startRelays || bootstrap != nil {
            do {
                try await coordinator.activate(
                    bindingID: policy.binding.bindingID,
                    endpointIdentity: policy.binding.endpointID,
                    bootstrap: bootstrap
                )
            } catch {
                // Registration remains authoritative. The coordinator schedules
                // a bounded retry and direct paths remain usable.
            }
        }
    }

    private func startSupervisorObservation(revision: UInt64) {
        supervisorEventTask?.cancel()
        supervisorEventTask = Task { [weak self] in
            guard let self else { return }
            let events = await supervisor.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .networkChanged:
                    await self.scheduleRegistrationRefresh(revision: revision)
                case let .recovered(_, newGeneration):
                    await self.sessionPool.activate(runtimeGeneration: newGeneration)
                    await self.scheduleRegistrationRefresh(revision: revision)
                case .snapshot:
                    break
                }
            }
        }
    }

    private func scheduleRegistrationRefresh(revision: UInt64) {
        guard desiredActive,
              lifecycleRevision == revision,
              registrationRefreshTask == nil else { return }
        registrationRefreshTask = Task { [weak self] in
            do {
                try await self?.refreshRegistration(revision: revision)
            } catch {
                // Terminal errors already revoke local policy and stop networking.
            }
        }
    }

    private func refreshRegistration(revision: UInt64) async throws {
        defer { registrationRefreshTask = nil }
        guard desiredActive,
              lifecycleRevision == revision,
              let previousBinding = localBinding else { return }
        do {
            let endpoint = try await supervisor.activeEndpoint()
            let endpointID = await endpoint.identity()
            let policy = try await resolvePolicy(
                expectedEndpointID: endpointID,
                revision: revision
            )
            guard policy.binding.bindingID == previousBinding.bindingID else {
                throw CmxIrohClientRuntimeError.invalidLocalBinding
            }
            try await install(policy: policy, revision: revision, startRelays: false)
            try requireCurrent(revision)
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            if let registration = policy.registration,
               let discovery = policy.discovery {
                await handleBinding(registration, discovery)
            } else if let lanRendezvous = policy.cachedLANRendezvous {
                await handleCachedBindings(policy.cachedTargetBindings, lanRendezvous)
            }
        } catch {
            guard !Self.isConnectivity(error) else {
                // Keep the last exact verified binding only while the broker is unreachable.
                return
            }
            desiredActive = false
            lifecycleRevision &+= 1
            currentSnapshot = CmxIrohClientRuntimeSnapshot(
                state: .failed,
                endpointID: nil,
                bindingID: previousBinding.bindingID
            )
            try? await offlinePolicyCache?.deactivate()
            await tearDownNetwork()
            await handlePolicyInvalidation()
            throw error
        }
    }

    private func tearDownNetwork() async {
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        supervisorEventTask?.cancel()
        supervisorEventTask = nil
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        await sessionPool.deactivate()
        await contextRouter.clear()
        localBinding = nil
        await supervisor.deactivate()
    }

    private func validateRelayFleet(_ fleet: [String]) throws {
        guard fleet.count == configuration.managedRelayURLs.count,
              Set(fleet) == configuration.managedRelayURLs else {
            throw CmxIrohClientRuntimeError.relayFleetMismatch
        }
    }

    private func requireCurrent(_ revision: UInt64) throws {
        guard desiredActive, lifecycleRevision == revision else {
            throw CmxIrohClientRuntimeError.superseded
        }
    }

    private static func cachedRelayConfigurations(
        configuration: CmxIrohClientRuntimeConfiguration,
        now: Date
    ) -> [CmxIrohRelayConfiguration] {
        guard let cached = configuration.cachedRelayCredential,
              cached.relayFleet.count == configuration.managedRelayURLs.count,
              Set(cached.relayFleet) == configuration.managedRelayURLs else {
            return []
        }
        return (try? cached.relayConfigurations(now: now)) ?? []
    }

    private static func isConnectivity(_ error: any Error) -> Bool {
        (error as? CmxIrohTrustBrokerClientError) == .connectivity
    }
}
