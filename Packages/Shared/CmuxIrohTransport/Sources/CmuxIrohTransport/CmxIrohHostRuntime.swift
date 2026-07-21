public import CMUXMobileCore
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

    struct ResolvedPolicy: Sendable {
        let registration: CmxIrohRegistrationResponse?
        let discovery: CmxIrohDiscoveryResponse?
        let binding: CmxIrohBrokerBindingMetadata
        let pairingEnabled: Bool
        let grantVerificationKeys: CmxIrohGrantVerificationKeySet
        let attestation: CmxIrohEndpointAttestationResponse?
        let relayBootstrap: CmxIrohRelayTokenResponse?
        let lanRendezvous: CmxIrohLANRendezvous
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

    let factory: any CmxIrohEndpointFactory
    let broker: any CmxIrohHostBrokerServing
    let configuration: CmxIrohHostRuntimeConfiguration
    let pendingRevocations: CmxIrohPendingRevocationOutbox
    let protocolConfiguration: CmxIrohProtocolConfiguration
    let now: @Sendable () -> Date
    let admissionClock: any CmxIrohRelayClock
    let registrationClock: any CmxIrohRelayClock
    let registrationRetrySchedule: CmxIrohRetrySchedule
    let registrationRetryJitter: @Sendable () -> Double
    let handleTransport: TransportHandler
    let handleBinding: BindingHandler
    let handleDeactivation: DeactivationHandler
    let handleRelayCredential: RelayCredentialHandler
    let handleLANRefresh: LANRefreshHandler
    let handleLANPolicy: LANPolicyHandler

    var lifecycleRevision: UInt64 = 0
    var lifecyclePhase = LifecyclePhase.inactive
    var signOutOperation: Task<CmxIrohHostSignOutPreparation, Never>?
    var supervisor: CmxIrohEndpointSupervisor?
    var relayCoordinator: CmxIrohRelayCredentialCoordinator?
    var endpointServer: CmxIrohEndpointServer?
    var admissionController: CmxIrohAdmissionController?
    var onlineAdmissionRegistry: CmxIrohOnlineAdmissionRegistry?
    var offlineSessions: CmxIrohOfflinePairingSessions?
    var supervisorEventTask: Task<Void, Never>?
    var relayActivationTask: Task<Void, Never>?
    var lanPublicationTask: Task<Void, Never>?
    var lanPublicationGeneration: UInt64 = 0
    var registrationRefreshTask: Task<Void, Never>?
    var registrationRenewalTask: Task<Void, Never>?
    var registrationRefreshPending = false
    var registrationRefreshEnabled = false
    var registrationRefreshFailureCount = 0
    var localBinding: CmxIrohBrokerBindingMetadata?
    var managedRelayURLs: Set<String>
    var currentEndpointRelayProfile: CmxIrohEndpointRelayProfile?
    var endpointAttestation: CmxIrohEndpointAttestationResponse?
    var lanRendezvous: CmxIrohLANRendezvous?
    var activePathConnections: [UUID: any CmxIrohConnection] = [:]
    var activePathConnectionOrder: [UUID] = []
    var activePathObservationTasks: [UUID: Task<Void, Never>] = [:]
    var selectedPathContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    var currentSnapshot = CmxIrohHostRuntimeSnapshot(
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
        registrationClock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        registrationRetrySchedule: CmxIrohRetrySchedule = CmxIrohRetrySchedule(),
        registrationRetryJitter: @escaping @Sendable () -> Double = {
            Double.random(in: 0 ... 1)
        },
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
        self.registrationClock = registrationClock
        self.registrationRetrySchedule = registrationRetrySchedule
        self.registrationRetryJitter = registrationRetryJitter
        self.handleTransport = handleTransport
        self.handleBinding = handleBinding
        self.handleDeactivation = handleDeactivation
        self.handleRelayCredential = handleRelayCredential
        self.handleLANRefresh = handleLANRefresh
        self.handleLANPolicy = handleLANPolicy
        managedRelayURLs = configuration.managedRelayURLs
        currentEndpointRelayProfile = configuration.endpointRelayProfile
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
        registrationRefreshFailureCount = 0
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .starting,
            endpointID: nil,
            bindingID: nil
        )

        do {
            let endpointRelayProfile = try (currentEndpointRelayProfile
                ?? configuration.resolvedEndpointRelayProfile(now: now()))
                .droppingExpiredManagedCredentials(at: now())
            currentEndpointRelayProfile = endpointRelayProfile
            let endpointConfiguration = CmxIrohEndpointConfiguration(
                secretKey: configuration.identity.secretKey,
                alpns: [protocolConfiguration.alpn],
                bindPolicy: configuration.bindPolicy,
                relayProfile: endpointRelayProfile
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

            let policy = try await resolveInitialPolicy(
                supervisor: supervisor,
                expectedEndpointID: endpointID,
                revision: revision
            )
            try requireCurrent(revision)

            let offlineSessions = CmxIrohOfflinePairingSessions(
                pairingEnabled: policy.pairingEnabled
            )
            let onlineAdmissionRegistry = CmxIrohOnlineAdmissionRegistry(
                broker: broker,
                keys: policy.grantVerificationKeys,
                acceptor: grantPeer(for: policy.binding),
                managedRelayURLs: managedRelayURLs,
                clock: admissionClock
            )
            let admissionController = CmxIrohAdmissionController(
                acceptor: grantPeer(for: policy.binding),
                pairingEnabled: policy.pairingEnabled,
                offlineSessions: offlineSessions,
                onlineRegistry: onlineAdmissionRegistry
            )
            let relayCoordinator: CmxIrohRelayCredentialCoordinator?
            if endpointRelayProfile.source == .managed,
               !endpointRelayProfile.allowedRelayURLs.isEmpty {
                relayCoordinator = CmxIrohRelayCredentialCoordinator(
                    supervisor: supervisor,
                    broker: broker,
                    managedRelayURLs: managedRelayURLs,
                    selectedRelayURLs: endpointRelayProfile.allowedRelayURLs,
                    credentialDidInstall: { [handleRelayCredential] response in
                        await handleRelayCredential(response, policy.binding)
                    }
                )
            } else {
                relayCoordinator = nil
            }

            self.offlineSessions = offlineSessions
            self.onlineAdmissionRegistry = onlineAdmissionRegistry
            self.admissionController = admissionController
            self.relayCoordinator = relayCoordinator
            localBinding = policy.binding
            endpointAttestation = policy.attestation
            lanRendezvous = policy.lanRendezvous

            let server = CmxIrohEndpointServer(supervisor: supervisor) { [weak self] connection, generation, markAdmitted in
                guard let self else {
                    await connection.close(errorCode: 1, reason: "runtime_deallocated")
                    return
                }
                try await self.admit(
                    connection: connection,
                    runtimeGeneration: generation,
                    lifecycleRevision: revision,
                    markAdmitted: markAdmitted
                )
            }
            endpointServer = server
            await server.start()
            try requireCurrent(revision)

            lifecyclePhase = .active
            currentSnapshot = CmxIrohHostRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            var publishedPolicy = policy
            let requiresRelayReadiness = !protocolConfiguration
                .allowsNATTraversalAfterAdmission
            if requiresRelayReadiness {
                if let relayCoordinator {
                    try await relayCoordinator.activate(
                        bindingID: policy.binding.bindingID,
                        endpointIdentity: endpointID,
                        bootstrap: policy.relayBootstrap,
                        waitForInitialCredential: true
                    )
                }
                try requireCurrent(revision)
                guard await supervisor.hasConfiguredRelay() else {
                    throw CmxIrohEndpointSupervisorError.relayReadinessTimedOut
                }
                try await supervisor.waitForUsableHomeRelay()
                try requireCurrent(revision)
                let readyPolicy = try await resolvePolicy(
                    supervisor: supervisor,
                    expectedEndpointID: endpointID,
                    revision: revision,
                    allowCachedFallback: false
                )
                guard readyPolicy.binding.bindingID == policy.binding.bindingID else {
                    throw CmxIrohHostRuntimeError.invalidLocalBinding
                }
                await admissionController.update(
                    keys: readyPolicy.grantVerificationKeys,
                    acceptor: grantPeer(for: readyPolicy.binding),
                    pairingEnabled: readyPolicy.pairingEnabled
                )
                try requireCurrent(revision)
                localBinding = readyPolicy.binding
                endpointAttestation = readyPolicy.attestation ?? endpointAttestation
                lanRendezvous = readyPolicy.lanRendezvous
                publishedPolicy = readyPolicy
                // The online event that released the barrier is already folded
                // into `readyPolicy`; do not immediately publish a third copy.
                registrationRefreshPending = false
            }
            if let registration = publishedPolicy.registration,
               let discovery = publishedPolicy.discovery {
                await handleBinding(registration, discovery, publishedPolicy.attestation)
                scheduleRegistrationRenewal(
                    binding: registration.binding,
                    revision: revision
                )
            }
            registrationRefreshEnabled = true
            if registrationRefreshPending {
                registrationRefreshPending = false
                scheduleRegistrationRefresh(revision: revision)
            }
            if let relayCoordinator, !requiresRelayReadiness {
                scheduleRelayActivation(
                    relayCoordinator,
                    binding: policy.binding,
                    endpointID: endpointID,
                    bootstrap: policy.relayBootstrap,
                    revision: revision
                )
            }
            scheduleLANPublication(
                binding: publishedPolicy.binding,
                rendezvous: publishedPolicy.lanRendezvous,
                supervisor: supervisor,
                revision: revision
            )
        } catch {
            guard lifecyclePhase.ownsNetworkOperation,
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


    private func admit(
        connection: any CmxIrohConnection,
        runtimeGeneration: UInt64,
        lifecycleRevision revision: UInt64,
        markAdmitted: @escaping CmxIrohEndpointServer.AdmissionMarker
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
        guard await markAdmitted() else {
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
        let pathConnectionID = UUID()
        activePathConnections[pathConnectionID] = connection
        activePathConnectionOrder.append(pathConnectionID)
        if let inspecting = connection as? any CmxIrohConnectionPathInspecting {
            activePathObservationTasks[pathConnectionID] = Task { [weak self] in
                let changes = await inspecting.observedSelectedPathChanges()
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await self?.publishSelectedPathChange(connectionID: pathConnectionID)
                }
            }
        }
        publishSelectedPathChange()
        defer {
            activePathObservationTasks[pathConnectionID]?.cancel()
            activePathObservationTasks[pathConnectionID] = nil
            activePathConnections[pathConnectionID] = nil
            activePathConnectionOrder.removeAll { $0 == pathConnectionID }
            publishSelectedPathChange()
        }
        await handleTransport(
            CmxIrohAdmittedServerSession(peer: peer, session: session),
            isCurrent
        )
    }

    func publishSelectedPathChange() {
        for continuation in selectedPathContinuations.values {
            continuation.yield(())
        }
    }

    func publishSelectedPathChange(connectionID: UUID) {
        guard activePathConnections[connectionID] != nil else { return }
        publishSelectedPathChange()
    }

    func removeSelectedPathContinuation(id: UUID) {
        selectedPathContinuations[id] = nil
    }

    private func isCurrent(revision: UInt64, runtimeGeneration: UInt64) async -> Bool {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              let endpointServer else { return false }
        return await endpointServer.isCurrent(runtimeGeneration: runtimeGeneration)
    }

    func requireCurrent(_ revision: UInt64) throws {
        guard lifecyclePhase.ownsNetworkOperation,
              lifecycleRevision == revision,
              !Task.isCancelled else {
            throw CmxIrohHostRuntimeError.superseded
        }
    }

    func grantPeer(
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

    func publishLANPolicy(
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

    func scheduleRelayActivation(
        _ coordinator: CmxIrohRelayCredentialCoordinator,
        binding: CmxIrohBrokerBindingMetadata,
        endpointID: CmxIrohPeerIdentity,
        bootstrap: CmxIrohRelayTokenResponse?,
        revision: UInt64
    ) {
        relayActivationTask?.cancel()
        relayActivationTask = Task { [weak self] in
            await self?.activateRelaySidecar(
                coordinator,
                binding: binding,
                endpointID: endpointID,
                bootstrap: bootstrap,
                revision: revision
            )
        }
    }

    private func activateRelaySidecar(
        _ coordinator: CmxIrohRelayCredentialCoordinator,
        binding: CmxIrohBrokerBindingMetadata,
        endpointID: CmxIrohPeerIdentity,
        bootstrap: CmxIrohRelayTokenResponse?,
        revision: UInt64
    ) async {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              relayCoordinator === coordinator,
              !Task.isCancelled else { return }
        do {
            try await coordinator.activate(
                bindingID: binding.bindingID,
                endpointIdentity: endpointID,
                bootstrap: bootstrap
            )
        } catch {
            // The coordinator owns bounded retry. A verified direct route stays
            // authoritative when relay credential installation is unavailable.
        }
        if relayCoordinator === coordinator {
            relayActivationTask = nil
        }
    }

    func scheduleLANPublication(
        binding: CmxIrohBrokerBindingMetadata,
        rendezvous: CmxIrohLANRendezvous,
        supervisor: CmxIrohEndpointSupervisor,
        revision: UInt64
    ) {
        lanPublicationGeneration &+= 1
        let generation = lanPublicationGeneration
        lanPublicationTask?.cancel()
        lanPublicationTask = Task { [weak self] in
            await self?.publishLANSidecar(
                binding: binding,
                rendezvous: rendezvous,
                supervisor: supervisor,
                revision: revision,
                generation: generation
            )
        }
    }

    private func publishLANSidecar(
        binding: CmxIrohBrokerBindingMetadata,
        rendezvous: CmxIrohLANRendezvous,
        supervisor: CmxIrohEndpointSupervisor,
        revision: UInt64,
        generation: UInt64
    ) async {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              lanPublicationGeneration == generation,
              !Task.isCancelled else { return }
        await publishLANPolicy(
            binding: binding,
            rendezvous: rendezvous,
            supervisor: supervisor
        )
    }

    func endpointExpectation(
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

    static func isConnectivityFailure(_ error: any Error) -> Bool {
        guard let brokerError = error as? CmxIrohTrustBrokerClientError else {
            return false
        }
        return brokerError == .connectivity
    }
}
