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
    var registrationRefreshTask: Task<Void, Never>?
    var registrationRefreshPending = false
    var registrationRefreshEnabled = false
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
        managedRelayURLs = configuration.managedRelayURLs
        currentEndpointRelayProfile = configuration.endpointRelayProfile
    }

    public func snapshot() -> CmxIrohHostRuntimeSnapshot {
        currentSnapshot
    }

    /// Returns the most recently admitted live path with coordinates removed.
    ///
    /// Relay attribution succeeds only when the selected relay is present in
    /// the exact verified effective policy installed by the composition root.
    ///
    /// - Parameter relayPolicy: The current verified effective relay policy.
    /// - Returns: A credential-free path category safe for settings and diagnostics.
    public func selectedTransportPath(
        relayPolicy: CmxIrohEffectiveRelayPolicy?
    ) async -> CmxIrohSelectedTransportPath {
        guard let id = activePathConnectionOrder.last,
              let connection = activePathConnections[id] as? any CmxIrohConnectionPathInspecting else {
            return .unavailable
        }
        let observed = await connection.observedSelectedPath()
        return CmxIrohSelectedTransportPathClassifier(policy: relayPolicy)
            .classify(observed)
    }

    /// Emits when admitted connection lifecycle may alter the selected path.
    ///
    /// Consumers re-read ``selectedTransportPath(relayPolicy:)`` for the
    /// credential-free value. The stream never carries raw path data.
    public func selectedTransportPathChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            selectedPathContinuations[id] = continuation
            continuation.yield(())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSelectedPathContinuation(id: id) }
            }
        }
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

            if let relayCoordinator {
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
