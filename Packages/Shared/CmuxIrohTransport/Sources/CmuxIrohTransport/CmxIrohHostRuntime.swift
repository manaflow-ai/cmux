import CMUXMobileCore
public import Foundation

/// Owns one account-scoped Mac endpoint, broker binding, relay rotation, and accept loop.
public actor CmxIrohHostRuntime {
    public typealias CurrentGeneration = @Sendable () async -> Bool
    public typealias TransportHandler = @Sendable (
        _ session: CmxIrohAdmittedServerSession,
        _ isCurrent: @escaping CurrentGeneration
    ) async -> Void
    public typealias BindingHandler = @Sendable (
        _ registration: CmxIrohRegistrationResponse,
        _ discovery: CmxIrohDiscoveryResponse,
        _ attestation: CmxIrohEndpointAttestationResponse?
    ) async -> Void
    /// Clears app-visible network state after the endpoint and accepts are closed.
    ///
    /// Persistent identity and credential deletion belongs to the caller and
    /// must remain conditional on a successfully queued sign-out revocation.
    public typealias DeactivationHandler = @Sendable (_ bindingID: String?) async -> Void
    public typealias RelayCredentialHandler = @Sendable (
        _ response: CmxIrohRelayTokenResponse,
        _ binding: CmxIrohBrokerBindingMetadata
    ) async -> Void
    public typealias LANRefreshHandler = @Sendable () async -> Void
    public typealias LANDirectAddressProvider = @Sendable () async -> [String]
    public typealias LANPolicyHandler = @Sendable (
        _ context: CmxIrohHostLANAdvertisementContext,
        _ directAddresses: @escaping LANDirectAddressProvider
    ) async -> Void

    private struct ResolvedPolicy: Sendable {
        let registration: CmxIrohRegistrationResponse?
        let discovery: CmxIrohDiscoveryResponse?
        let binding: CmxIrohBrokerBindingMetadata
        let pairingEnabled: Bool
        let grantVerificationKeys: CmxIrohGrantVerificationKeySet
        let attestation: CmxIrohEndpointAttestationResponse?
        let relayBootstrap: CmxIrohRelayTokenResponse?
        let lanRendezvous: CmxIrohLANRendezvous
    }

    private enum LifecyclePhase: Equatable, Sendable {
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

    private let factory: any CmxIrohEndpointFactory
    private let broker: any CmxIrohHostBrokerServing
    private let configuration: CmxIrohHostRuntimeConfiguration
    private let pendingRevocations: CmxIrohPendingRevocationOutbox
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let now: @Sendable () -> Date
    private let admissionClock: any CmxIrohRelayClock
    private let handleTransport: TransportHandler
    private let handleBinding: BindingHandler
    private let handleDeactivation: DeactivationHandler
    private let handleRelayCredential: RelayCredentialHandler
    private let handleLANRefresh: LANRefreshHandler
    private let handleLANPolicy: LANPolicyHandler

    private var lifecycleRevision: UInt64 = 0
    private var lifecyclePhase = LifecyclePhase.inactive
    private var signOutOperation: Task<CmxIrohHostSignOutPreparation, Never>?
    private var supervisor: CmxIrohEndpointSupervisor?
    private var relayCoordinator: CmxIrohRelayCredentialCoordinator?
    private var endpointServer: CmxIrohEndpointServer?
    private var admissionController: CmxIrohAdmissionController?
    private var onlineAdmissionRegistry: CmxIrohOnlineAdmissionRegistry?
    private var offlineSessions: CmxIrohOfflinePairingSessions?
    private var supervisorEventTask: Task<Void, Never>?
    private var registrationRefreshTask: Task<Void, Never>?
    private var registrationRefreshPending = false
    private var registrationRefreshEnabled = false
    private var localBinding: CmxIrohBrokerBindingMetadata?
    private var endpointAttestation: CmxIrohEndpointAttestationResponse?
    private var lanRendezvous: CmxIrohLANRendezvous?
    private var currentSnapshot = CmxIrohHostRuntimeSnapshot(
        state: .inactive,
        endpointID: nil,
        bindingID: nil
    )

    public init(
        factory: any CmxIrohEndpointFactory,
        broker: any CmxIrohHostBrokerServing,
        configuration: CmxIrohHostRuntimeConfiguration,
        pendingRevocations: CmxIrohPendingRevocationOutbox,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        now: @escaping @Sendable () -> Date = { Date() },
        admissionClock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        handleTransport: @escaping TransportHandler,
        handleBinding: @escaping BindingHandler = { _, _, _ in },
        handleDeactivation: @escaping DeactivationHandler = { _ in },
        handleRelayCredential: @escaping RelayCredentialHandler = { _, _ in },
        handleLANRefresh: @escaping LANRefreshHandler = {},
        handleLANPolicy: @escaping LANPolicyHandler = { _, _ in }
    ) {
        self.factory = factory
        self.broker = broker
        self.configuration = configuration
        self.pendingRevocations = pendingRevocations
        self.protocolConfiguration = protocolConfiguration
        self.now = now
        self.admissionClock = admissionClock
        self.handleTransport = handleTransport
        self.handleBinding = handleBinding
        self.handleDeactivation = handleDeactivation
        self.handleRelayCredential = handleRelayCredential
        self.handleLANRefresh = handleLANRefresh
        self.handleLANPolicy = handleLANPolicy
    }

    public func snapshot() -> CmxIrohHostRuntimeSnapshot {
        currentSnapshot
    }

    /// Returns current verified private alias material without broker path hints.
    public func lanAdvertisementContext() -> CmxIrohHostLANAdvertisementContext? {
        guard lifecyclePhase == .active,
              let localBinding,
              let lanRendezvous else { return nil }
        return CmxIrohHostLANAdvertisementContext(
            binding: localBinding,
            rendezvous: lanRendezvous
        )
    }

    /// Reads raw local direct addresses only for the interface-filtering publisher.
    public func localDirectAddresses() async -> [String] {
        guard lifecyclePhase == .active,
              let endpoint = try? await supervisor?.activeEndpoint() else { return [] }
        return await endpoint.localDirectAddresses()
    }

    /// Activates connectivity and resolves authenticated broker policy before any cached fallback.
    public func start() async throws {
        guard lifecyclePhase.allowsStart else {
            throw CmxIrohHostRuntimeError.alreadyActive
        }
        lifecyclePhase = .starting
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        registrationRefreshPending = false
        registrationRefreshEnabled = false
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .starting,
            endpointID: nil,
            bindingID: nil
        )

        do {
            let cachedRelays = cachedRelayConfigurations()
            let endpointConfiguration = try CmxIrohEndpointConfiguration(
                secretKey: configuration.identity.secretKey,
                alpns: [protocolConfiguration.alpn],
                bindPolicy: configuration.bindPolicy,
                managedRelayURLs: configuration.managedRelayURLs,
                relays: cachedRelays
            )
            let supervisor = CmxIrohEndpointSupervisor(
                factory: factory,
                configuration: endpointConfiguration
            )
            self.supervisor = supervisor
            await startSupervisorObservation(
                supervisor: supervisor,
                revision: revision
            )
            let endpointSnapshot = try await supervisor.activate()
            try requireCurrent(revision)
            guard let endpointID = endpointSnapshot.identity else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }

            let policy = try await resolvePolicy(
                supervisor: supervisor,
                expectedEndpointID: endpointID,
                revision: revision,
                allowCachedFallback: true
            )
            try requireCurrent(revision)

            let offlineSessions = CmxIrohOfflinePairingSessions(
                pairingEnabled: policy.pairingEnabled
            )
            let onlineAdmissionRegistry = CmxIrohOnlineAdmissionRegistry(
                broker: broker,
                keys: policy.grantVerificationKeys,
                acceptor: grantPeer(for: policy.binding),
                managedRelayURLs: configuration.managedRelayURLs,
                clock: admissionClock
            )
            let admissionController = CmxIrohAdmissionController(
                acceptor: grantPeer(for: policy.binding),
                pairingEnabled: policy.pairingEnabled,
                offlineSessions: offlineSessions,
                onlineRegistry: onlineAdmissionRegistry
            )
            let relayCoordinator = CmxIrohRelayCredentialCoordinator(
                supervisor: supervisor,
                broker: broker,
                managedRelayURLs: configuration.managedRelayURLs,
                credentialDidInstall: { [handleRelayCredential] response in
                    await handleRelayCredential(response, policy.binding)
                }
            )

            self.offlineSessions = offlineSessions
            self.onlineAdmissionRegistry = onlineAdmissionRegistry
            self.admissionController = admissionController
            self.relayCoordinator = relayCoordinator
            localBinding = policy.binding
            endpointAttestation = policy.attestation
            lanRendezvous = policy.lanRendezvous

            let server = CmxIrohEndpointServer(supervisor: supervisor) { [weak self] connection, generation in
                guard let self else {
                    await connection.close(errorCode: 1, reason: "runtime_deallocated")
                    return
                }
                try await self.admit(
                    connection: connection,
                    runtimeGeneration: generation,
                    lifecycleRevision: revision
                )
            }
            endpointServer = server
            await server.start()

            do {
                try await relayCoordinator.activate(
                    bindingID: policy.binding.bindingID,
                    endpointIdentity: endpointID,
                    bootstrap: policy.relayBootstrap
                )
            } catch {
                // The coordinator schedules a bounded broker retry. Direct paths
                // remain available and the binding stays authoritative.
            }

            lifecyclePhase = .active
            currentSnapshot = CmxIrohHostRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            await publishLANPolicy(
                binding: policy.binding,
                rendezvous: policy.lanRendezvous,
                supervisor: supervisor
            )
            try requireCurrent(revision)
            if let registration = policy.registration,
               let discovery = policy.discovery {
                await handleBinding(registration, discovery, policy.attestation)
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
            currentSnapshot = CmxIrohHostRuntimeSnapshot(
                state: .failed,
                endpointID: nil,
                bindingID: localBinding?.bindingID
            )
            await tearDownComponents(notify: true)
            if lifecyclePhase == .stopping,
               lifecycleRevision == revision {
                lifecyclePhase = .failed
            }
            throw error
        }
    }

    /// Stops accepts, closes the endpoint, and invalidates generation-owned work.
    public func stop() async {
        guard lifecyclePhase == .starting || lifecyclePhase == .active else {
            return
        }
        lifecyclePhase = .stopping
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .stopping,
            endpointID: currentSnapshot.endpointID,
            bindingID: localBinding?.bindingID
        )
        await tearDownComponents(notify: true)
        guard lifecyclePhase == .stopping,
              lifecycleRevision == revision else { return }
        lifecyclePhase = .inactive
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .inactive,
            endpointID: nil,
            bindingID: nil
        )
    }

    /// Closes networking, durably queues revocation, then deactivates local state.
    ///
    /// The binding is captured and the lifecycle enters `signingOut` before the
    /// first suspension. Endpoint teardown and device-only persistence run
    /// concurrently. App-visible network state is cleared on either outcome.
    /// Persistence failure leaves identity state and the binding quarantined.
    /// Calling this method again while quarantined retries the durable enqueue.
    ///
    /// - Returns: The prior binding and whether it was durably queued.
    public func deactivateForSignOut() async -> CmxIrohHostSignOutPreparation {
        if let signOutOperation {
            return await signOutOperation.value
        }
        let requiresNetworkDeactivation = lifecyclePhase != .quarantined
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
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .signingOut,
            endpointID: currentSnapshot.endpointID,
            bindingID: pendingRevocation?.bindingID
        )

        let operation = Task {
            await self.performSignOut(
                pendingRevocation: pendingRevocation,
                requiresNetworkDeactivation: requiresNetworkDeactivation,
                revision: revision
            )
        }
        signOutOperation = operation
        return await operation.value
    }

    /// Creates a one-use five-minute offline invitation from the latest broker proof.
    public func createOfflinePairingInvitation() async throws -> CmxIrohOfflinePairingInvitation {
        guard lifecyclePhase == .active,
              let offlineSessions,
              let binding = localBinding,
              let attestation = endpointAttestation else {
            throw CmxIrohHostRuntimeError.inactive
        }
        return try await offlineSessions.createInvitation(
            acceptorAttestation: attestation.attestation,
            keys: attestation.grantVerificationKeys,
            acceptor: endpointExpectation(for: binding),
            now: now()
        )
    }

    private func resolvePolicy(
        supervisor: CmxIrohEndpointSupervisor,
        expectedEndpointID: CmxIrohPeerIdentity,
        revision: UInt64,
        allowCachedFallback: Bool
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
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let publicHints = Array(address.pathHints.compactMap {
            $0.publicDisclosure(at: now())
        }.prefix(CmxAttachEndpoint.maximumIrohPathHintCount))
        let payload = try CmxIrohRegistrationPayload(
            deviceID: configuration.deviceID,
            appInstanceID: configuration.appInstanceID,
            tag: configuration.tag,
            platform: .mac,
            displayName: configuration.displayName,
            endpointID: expectedEndpointID.endpointID,
            identityGeneration: configuration.identity.generation,
            pairingEnabled: configuration.pairingEnabled,
            capabilities: configuration.capabilities,
            pathHints: publicHints,
            now: now()
        )
        let signer = try CmxIrohRegistrationSigner(
            identity: configuration.identity,
            endpointID: expectedEndpointID.endpointID
        )
        let prepared = try signer.prepare(payload: payload)
        let registration: CmxIrohRegistrationResponse
        do {
            registration = try await broker.register(prepared: prepared, signer: signer)
        } catch {
            return try cachedPolicy(
                after: error,
                expectedEndpointID: expectedEndpointID,
                confirmedBinding: nil,
                relayBootstrap: nil,
                allowFallback: allowCachedFallback
            )
        }
        try requireCurrent(revision)
        try validateLocalBinding(registration.binding, endpointID: expectedEndpointID)
        if case let .issued(relay) = registration.relay {
            guard Set(relay.relayFleet) == configuration.managedRelayURLs,
                  relay.relayFleet.count == configuration.managedRelayURLs.count else {
                throw CmxIrohHostRuntimeError.relayFleetMismatch
            }
        }

        let discovery: CmxIrohDiscoveryResponse
        do {
            discovery = try await broker.discover()
        } catch {
            let relayBootstrap: CmxIrohRelayTokenResponse?
            switch registration.relay {
            case let .issued(response): relayBootstrap = response
            case .unavailable, .notRequested: relayBootstrap = nil
            }
            return try cachedPolicy(
                after: error,
                expectedEndpointID: expectedEndpointID,
                confirmedBinding: registration.binding,
                relayBootstrap: relayBootstrap,
                allowFallback: allowCachedFallback
            )
        }
        try requireCurrent(revision)
        guard discovery.routeContractVersion == payload.routeContractVersion else {
            throw CmxIrohHostRuntimeError.routeContractMismatch
        }
        guard Set(discovery.relayFleet) == configuration.managedRelayURLs,
              discovery.relayFleet.count == configuration.managedRelayURLs.count else {
            throw CmxIrohHostRuntimeError.relayFleetMismatch
        }
        guard let discovered = discovery.bindings.first(where: {
            $0.bindingID == registration.binding.bindingID
        }) else {
            throw CmxIrohHostRuntimeError.localBindingMissingFromDiscovery
        }
        try validateLocalBinding(discovered, endpointID: expectedEndpointID)
        let attestation = try? await broker.issueEndpointAttestation(
            bindingID: discovered.bindingID
        )
        try requireCurrent(revision)
        return ResolvedPolicy(
            registration: registration,
            discovery: discovery,
            binding: CmxIrohBrokerBindingMetadata(binding: discovered),
            pairingEnabled: discovered.pairingEnabled,
            grantVerificationKeys: discovery.grantVerificationKeys,
            attestation: attestation,
            relayBootstrap: registrationRelayBootstrap(registration),
            lanRendezvous: discovery.lanRendezvous
        )
    }

    private func cachedPolicy(
        after error: any Error,
        expectedEndpointID: CmxIrohPeerIdentity,
        confirmedBinding: CmxIrohBrokerBinding?,
        relayBootstrap: CmxIrohRelayTokenResponse?,
        allowFallback: Bool
    ) throws -> ResolvedPolicy {
        if let confirmedBinding, let localBinding,
           CmxIrohBrokerBindingMetadata(binding: confirmedBinding) != localBinding {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        guard allowFallback, Self.isConnectivityFailure(error),
              let cached = configuration.cachedHostPolicy else {
            throw error
        }
        try validateCachedPolicy(cached, endpointID: expectedEndpointID)
        if let confirmedBinding {
            guard CmxIrohBrokerBindingMetadata(binding: confirmedBinding) == cached.binding,
                  confirmedBinding.pairingEnabled == cached.pairingEnabled,
                  confirmedBinding.capabilities.count == cached.capabilities.count,
                  Set(confirmedBinding.capabilities) == Set(cached.capabilities) else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
        }
        return ResolvedPolicy(
            registration: nil,
            discovery: nil,
            binding: cached.binding,
            pairingEnabled: cached.pairingEnabled,
            grantVerificationKeys: cached.grantVerificationKeys,
            attestation: cached.endpointAttestation,
            relayBootstrap: relayBootstrap ?? configuration.cachedRelayCredential,
            lanRendezvous: cached.lanRendezvous
        )
    }

    private func validateLocalBinding(
        _ binding: CmxIrohBrokerBinding,
        endpointID: CmxIrohPeerIdentity
    ) throws {
        guard binding.deviceID == configuration.deviceID,
              binding.appInstanceID == configuration.appInstanceID,
              binding.tag == configuration.tag,
              binding.platform == .mac,
              binding.endpointID == endpointID,
              binding.identityGeneration == configuration.identity.generation,
              binding.pairingEnabled == configuration.pairingEnabled,
              Set(binding.capabilities) == Set(configuration.capabilities),
              binding.capabilities.count == configuration.capabilities.count else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
    }

    private func validateCachedPolicy(
        _ policy: CmxIrohCachedHostPolicy,
        endpointID: CmxIrohPeerIdentity
    ) throws {
        let binding = policy.binding
        guard binding.deviceID == configuration.deviceID,
              binding.appInstanceID == configuration.appInstanceID,
              binding.tag == configuration.tag,
              binding.platform == .mac,
              binding.endpointID == endpointID,
              binding.identityGeneration == configuration.identity.generation,
              policy.pairingEnabled == configuration.pairingEnabled,
              policy.capabilities.count == configuration.capabilities.count,
              Set(policy.capabilities) == Set(configuration.capabilities),
              policy.endpointAttestation.grantVerificationKeys
                  == policy.grantVerificationKeys else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let validationTime = now()
        let claims = try CmxIrohGrantVerifier().verifyEndpointAttestation(
            policy.endpointAttestation.attestation,
            keys: policy.grantVerificationKeys,
            expected: endpointExpectation(for: binding),
            now: validationTime
        )
        guard let envelopeExpiry = Self.date(policy.endpointAttestation.expiresAt),
              Self.seconds(envelopeExpiry) == claims.expiresAt,
              envelopeExpiry > validationTime else {
            throw CmxIrohHostPolicyCacheError.invalidAttestationEnvelope
        }
    }

    private func cachedRelayConfigurations() -> [CmxIrohRelayConfiguration] {
        guard let cached = configuration.cachedRelayCredential,
              Set(cached.relayFleet) == configuration.managedRelayURLs,
              cached.relayFleet.count == configuration.managedRelayURLs.count else {
            return []
        }
        return (try? cached.relayConfigurations(now: now())) ?? []
    }

    private func startSupervisorObservation(
        supervisor: CmxIrohEndpointSupervisor,
        revision: UInt64
    ) async {
        supervisorEventTask?.cancel()
        let events = await supervisor.events()
        supervisorEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .networkChanged, .recovered:
                    await self?.handleSupervisorNetworkChange(revision: revision)
                case .snapshot:
                    break
                }
            }
        }
    }

    private func handleSupervisorNetworkChange(revision: UInt64) async {
        guard lifecycleRevision == revision,
              lifecyclePhase.ownsNetworkOperation else { return }
        await handleLANRefresh()
        guard lifecycleRevision == revision,
              lifecyclePhase.ownsNetworkOperation else { return }
        guard registrationRefreshEnabled else {
            registrationRefreshPending = true
            return
        }
        scheduleRegistrationRefresh(revision: revision)
    }

    private func scheduleRegistrationRefresh(revision: UInt64) {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              registrationRefreshTask == nil else { return }
        registrationRefreshTask = Task { [weak self] in
            await self?.refreshRegistration(revision: revision)
        }
    }

    private func refreshRegistration(revision: UInt64) async {
        defer { registrationRefreshTask = nil }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let supervisor,
              let admissionController,
              let previousBinding = localBinding else { return }
        do {
            let endpoint = try await supervisor.activeEndpoint()
            let endpointID = await endpoint.identity()
            let policy = try await resolvePolicy(
                supervisor: supervisor,
                expectedEndpointID: endpointID,
                revision: revision,
                allowCachedFallback: false
            )
            guard policy.binding.bindingID == previousBinding.bindingID else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            await admissionController.update(
                keys: policy.grantVerificationKeys,
                acceptor: grantPeer(for: policy.binding),
                pairingEnabled: policy.pairingEnabled
            )
            try requireCurrent(revision)
            localBinding = policy.binding
            endpointAttestation = policy.attestation ?? endpointAttestation
            lanRendezvous = policy.lanRendezvous
            await publishLANPolicy(
                binding: policy.binding,
                rendezvous: policy.lanRendezvous,
                supervisor: supervisor
            )
            try requireCurrent(revision)
            guard let registration = policy.registration,
                  let discovery = policy.discovery else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            await handleBinding(registration, discovery, policy.attestation)
        } catch is CancellationError {
            return
        } catch {
            guard Self.preservesVerifiedPolicyDuringRefresh(error) else {
                lifecyclePhase = .stopping
                lifecycleRevision &+= 1
                let failureRevision = lifecycleRevision
                currentSnapshot = CmxIrohHostRuntimeSnapshot(
                    state: .failed,
                    endpointID: nil,
                    bindingID: localBinding?.bindingID
                )
                await tearDownComponents(notify: true)
                if lifecyclePhase == .stopping,
                   lifecycleRevision == failureRevision {
                    lifecyclePhase = .failed
                }
                return
            }
            // A connectivity outage or broker throttle cannot invalidate policy
            // that this generation already authenticated. The next real network
            // change can retry without a local busy loop.
        }
    }

    private func admit(
        connection: any CmxIrohConnection,
        runtimeGeneration: UInt64,
        lifecycleRevision revision: UInt64
    ) async throws {
        try requireCurrent(revision)
        guard let admissionController,
              let endpointServer,
              await endpointServer.isCurrent(runtimeGeneration: runtimeGeneration) else {
            throw CmxIrohHostRuntimeError.superseded
        }
        let session = try CmxIrohServerSession(
            connection: connection,
            authorizer: admissionController,
            protocolConfiguration: protocolConfiguration
        )
        let peer = try await session.admit()
        let onlineLease = try await session.admittedOnlineLease()
        guard await isCurrent(revision: revision, runtimeGeneration: runtimeGeneration) else {
            await session.close()
            throw CmxIrohHostRuntimeError.superseded
        }
        let isCurrent: CurrentGeneration = { [weak self] in
            await self?.isCurrent(
                revision: revision,
                runtimeGeneration: runtimeGeneration
            ) ?? false
        }
        if let onlineLease, let onlineAdmissionRegistry {
            await onlineAdmissionRegistry.monitor(
                onlineLease,
                connection: connection
            ) {
                await session.close()
            }
        }
        await handleTransport(
            CmxIrohAdmittedServerSession(peer: peer, session: session),
            isCurrent
        )
    }

    private func isCurrent(revision: UInt64, runtimeGeneration: UInt64) async -> Bool {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let endpointServer else { return false }
        return await endpointServer.isCurrent(runtimeGeneration: runtimeGeneration)
    }

    private func requireCurrent(_ revision: UInt64) throws {
        guard lifecyclePhase.ownsNetworkOperation,
              lifecycleRevision == revision,
              !Task.isCancelled else {
            throw CmxIrohHostRuntimeError.superseded
        }
    }

    private func grantPeer(
        for binding: CmxIrohBrokerBindingMetadata
    ) -> CmxIrohGrantPeer {
        CmxIrohGrantPeer(
            bindingID: binding.bindingID,
            deviceID: binding.deviceID,
            tag: binding.tag,
            platform: binding.platform,
            endpointID: binding.endpointID,
            identityGeneration: binding.identityGeneration
        )
    }

    private func publishLANPolicy(
        binding: CmxIrohBrokerBindingMetadata,
        rendezvous: CmxIrohLANRendezvous,
        supervisor: CmxIrohEndpointSupervisor
    ) async {
        let context = CmxIrohHostLANAdvertisementContext(
            binding: binding,
            rendezvous: rendezvous
        )
        let directAddresses: LANDirectAddressProvider = {
            guard let endpoint = try? await supervisor.activeEndpoint() else { return [] }
            return await endpoint.localDirectAddresses()
        }
        await handleLANPolicy(context, directAddresses)
    }

    private func endpointExpectation(
        for binding: CmxIrohBrokerBindingMetadata
    ) -> CmxIrohEndpointExpectation {
        CmxIrohEndpointExpectation(
            bindingID: binding.bindingID,
            deviceID: binding.deviceID,
            endpointID: binding.endpointID,
            identityGeneration: binding.identityGeneration,
            platform: binding.platform
        )
    }

    private func registrationRelayBootstrap(
        _ registration: CmxIrohRegistrationResponse
    ) -> CmxIrohRelayTokenResponse? {
        switch registration.relay {
        case let .issued(response): response
        case .unavailable, .notRequested: configuration.cachedRelayCredential
        }
    }

    private static func isConnectivityFailure(_ error: any Error) -> Bool {
        guard let brokerError = error as? CmxIrohTrustBrokerClientError else {
            return false
        }
        return brokerError == .connectivity
    }

    private static func preservesVerifiedPolicyDuringRefresh(
        _ error: any Error
    ) -> Bool {
        if isConnectivityFailure(error) { return true }
        guard let brokerError = error as? CmxIrohTrustBrokerClientError,
              case let .rejected(statusCode, _) = brokerError else {
            return false
        }
        return statusCode == 429
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func seconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
              value >= TimeInterval(Int64.min),
              value <= TimeInterval(Int64.max) else {
            return nil
        }
        return Int64(value.rounded(.down))
    }

    private func performSignOut(
        pendingRevocation: CmxIrohPendingRevocation?,
        requiresNetworkDeactivation: Bool,
        revision: UInt64
    ) async -> CmxIrohHostSignOutPreparation {
        async let wasPersisted = Self.persist(
            pendingRevocation,
            to: pendingRevocations
        )
        async let networkTeardown: Void = deactivateNetworkForSignOut(
            bindingID: pendingRevocation?.bindingID,
            required: requiresNetworkDeactivation
        )
        let (persisted, _) = await (wasPersisted, networkTeardown)
        let preparation = CmxIrohHostSignOutPreparation(
            pendingRevocation: pendingRevocation,
            wasPersisted: persisted
        )

        guard lifecyclePhase == .signingOut,
              lifecycleRevision == revision else {
            signOutOperation = nil
            return preparation
        }
        guard persisted else {
            lifecyclePhase = .quarantined
            currentSnapshot = CmxIrohHostRuntimeSnapshot(
                state: .quarantined,
                endpointID: nil,
                bindingID: pendingRevocation?.bindingID
            )
            signOutOperation = nil
            return preparation
        }

        localBinding = nil
        lifecyclePhase = .inactive
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .inactive,
            endpointID: nil,
            bindingID: nil
        )
        signOutOperation = nil
        return preparation
    }

    private nonisolated static func persist(
        _ revocation: CmxIrohPendingRevocation?,
        to pendingRevocations: CmxIrohPendingRevocationOutbox
    ) async -> Bool {
        guard let revocation else { return true }
        do {
            try await pendingRevocations.enqueue(revocation)
            return true
        } catch {
            return false
        }
    }

    private func deactivateNetworkForSignOut(
        bindingID: String?,
        required: Bool
    ) async {
        guard required else { return }
        await tearDownComponents(notify: false, preserveBinding: true)
        await handleDeactivation(bindingID)
    }

    private func tearDownComponents(
        notify: Bool,
        preserveBinding: Bool = false
    ) async {
        supervisorEventTask?.cancel()
        supervisorEventTask = nil
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        registrationRefreshPending = false
        registrationRefreshEnabled = false
        await endpointServer?.stop()
        endpointServer = nil
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        await offlineSessions?.invalidate()
        offlineSessions = nil
        await onlineAdmissionRegistry?.stop()
        onlineAdmissionRegistry = nil
        admissionController = nil
        let bindingID = localBinding?.bindingID
        if !preserveBinding {
            localBinding = nil
        }
        endpointAttestation = nil
        lanRendezvous = nil
        await supervisor?.deactivate()
        supervisor = nil
        if notify { await handleDeactivation(bindingID) }
    }
}
