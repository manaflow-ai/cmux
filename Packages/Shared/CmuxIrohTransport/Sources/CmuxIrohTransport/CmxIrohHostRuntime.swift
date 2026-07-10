public import CMUXMobileCore
public import Foundation

/// Owns one account-scoped Mac endpoint, broker binding, relay rotation, and accept loop.
public actor CmxIrohHostRuntime {
    public typealias CurrentGeneration = @Sendable () async -> Bool
    public typealias TransportHandler = @Sendable (
        _ transport: any CmxByteTransport,
        _ peer: CmxIrohAdmittedPeer,
        _ isCurrent: @escaping CurrentGeneration
    ) async -> Void
    public typealias BindingHandler = @Sendable (
        _ registration: CmxIrohRegistrationResponse,
        _ discovery: CmxIrohDiscoveryResponse,
        _ attestation: CmxIrohEndpointAttestationResponse?
    ) async -> Void
    public typealias DeactivationHandler = @Sendable (_ bindingID: String?) async -> Void
    public typealias RelayCredentialHandler = @Sendable (
        _ response: CmxIrohRelayTokenResponse,
        _ binding: CmxIrohBrokerBindingMetadata
    ) async -> Void

    private struct ResolvedPolicy: Sendable {
        let registration: CmxIrohRegistrationResponse?
        let discovery: CmxIrohDiscoveryResponse?
        let binding: CmxIrohBrokerBindingMetadata
        let pairingEnabled: Bool
        let grantVerificationKeys: CmxIrohGrantVerificationKeySet
        let attestation: CmxIrohEndpointAttestationResponse?
        let relayBootstrap: CmxIrohRelayTokenResponse?
    }

    private let factory: any CmxIrohEndpointFactory
    private let broker: any CmxIrohHostBrokerServing
    private let configuration: CmxIrohHostRuntimeConfiguration
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let now: @Sendable () -> Date
    private let handleTransport: TransportHandler
    private let handleBinding: BindingHandler
    private let handleDeactivation: DeactivationHandler
    private let handleRelayCredential: RelayCredentialHandler

    private var lifecycleRevision: UInt64 = 0
    private var desiredActive = false
    private var supervisor: CmxIrohEndpointSupervisor?
    private var relayCoordinator: CmxIrohRelayCredentialCoordinator?
    private var endpointServer: CmxIrohEndpointServer?
    private var admissionController: CmxIrohAdmissionController?
    private var offlineSessions: CmxIrohOfflinePairingSessions?
    private var supervisorEventTask: Task<Void, Never>?
    private var registrationRefreshTask: Task<Void, Never>?
    private var localBinding: CmxIrohBrokerBindingMetadata?
    private var endpointAttestation: CmxIrohEndpointAttestationResponse?
    private var currentSnapshot = CmxIrohHostRuntimeSnapshot(
        state: .inactive,
        endpointID: nil,
        bindingID: nil
    )

    public init(
        factory: any CmxIrohEndpointFactory,
        broker: any CmxIrohHostBrokerServing,
        configuration: CmxIrohHostRuntimeConfiguration,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        now: @escaping @Sendable () -> Date = { Date() },
        handleTransport: @escaping TransportHandler,
        handleBinding: @escaping BindingHandler = { _, _, _ in },
        handleDeactivation: @escaping DeactivationHandler = { _ in },
        handleRelayCredential: @escaping RelayCredentialHandler = { _, _ in }
    ) {
        self.factory = factory
        self.broker = broker
        self.configuration = configuration
        self.protocolConfiguration = protocolConfiguration
        self.now = now
        self.handleTransport = handleTransport
        self.handleBinding = handleBinding
        self.handleDeactivation = handleDeactivation
        self.handleRelayCredential = handleRelayCredential
    }

    public func snapshot() -> CmxIrohHostRuntimeSnapshot {
        currentSnapshot
    }

    /// Activates connectivity and resolves authenticated broker policy before any cached fallback.
    public func start() async throws {
        guard !desiredActive else { throw CmxIrohHostRuntimeError.alreadyActive }
        desiredActive = true
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
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
            let admissionController = CmxIrohAdmissionController(
                keys: policy.grantVerificationKeys,
                acceptor: grantPeer(for: policy.binding),
                pairingEnabled: policy.pairingEnabled,
                offlineSessions: offlineSessions
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
            self.admissionController = admissionController
            self.relayCoordinator = relayCoordinator
            localBinding = policy.binding
            endpointAttestation = policy.attestation

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

            startSupervisorObservation(supervisor: supervisor, revision: revision)
            currentSnapshot = CmxIrohHostRuntimeSnapshot(
                state: .active,
                endpointID: endpointID,
                bindingID: policy.binding.bindingID
            )
            if let registration = policy.registration,
               let discovery = policy.discovery {
                await handleBinding(registration, discovery, policy.attestation)
            }
        } catch {
            currentSnapshot = CmxIrohHostRuntimeSnapshot(
                state: .failed,
                endpointID: nil,
                bindingID: localBinding?.bindingID
            )
            await tearDownComponents(notify: true)
            desiredActive = false
            throw error
        }
    }

    /// Stops accepts, closes the endpoint, and invalidates generation-owned work.
    public func stop() async {
        guard desiredActive || supervisor != nil else { return }
        desiredActive = false
        lifecycleRevision &+= 1
        await tearDownComponents(notify: true)
        currentSnapshot = CmxIrohHostRuntimeSnapshot(
            state: .inactive,
            endpointID: nil,
            bindingID: nil
        )
    }

    /// Creates a one-use five-minute offline invitation from the latest broker proof.
    public func createOfflinePairingInvitation() async throws -> CmxIrohOfflinePairingInvitation {
        guard desiredActive,
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
            case .unavailable: relayBootstrap = nil
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
            relayBootstrap: registrationRelayBootstrap(registration)
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
            relayBootstrap: relayBootstrap ?? configuration.cachedRelayCredential
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
    ) {
        supervisorEventTask?.cancel()
        supervisorEventTask = Task { [weak self] in
            let events = await supervisor.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .networkChanged, .recovered:
                    await self?.scheduleRegistrationRefresh(revision: revision)
                case .snapshot:
                    break
                }
            }
        }
    }

    private func scheduleRegistrationRefresh(revision: UInt64) {
        guard desiredActive, lifecycleRevision == revision,
              registrationRefreshTask == nil else { return }
        registrationRefreshTask = Task { [weak self] in
            await self?.refreshRegistration(revision: revision)
        }
    }

    private func refreshRegistration(revision: UInt64) async {
        defer { registrationRefreshTask = nil }
        guard desiredActive, lifecycleRevision == revision,
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
            guard let registration = policy.registration,
                  let discovery = policy.discovery else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }
            await handleBinding(registration, discovery, policy.attestation)
        } catch is CancellationError {
            return
        } catch {
            guard Self.isConnectivityFailure(error) else {
                desiredActive = false
                currentSnapshot = CmxIrohHostRuntimeSnapshot(
                    state: .failed,
                    endpointID: nil,
                    bindingID: localBinding?.bindingID
                )
                await tearDownComponents(notify: true)
                return
            }
            // Preserve verified policy only while the authenticated broker is unreachable.
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
        guard await isCurrent(revision: revision, runtimeGeneration: runtimeGeneration) else {
            await session.close()
            throw CmxIrohHostRuntimeError.superseded
        }
        let transport = CmxIrohServerByteTransport(session: session)
        let isCurrent: CurrentGeneration = { [weak self] in
            await self?.isCurrent(
                revision: revision,
                runtimeGeneration: runtimeGeneration
            ) ?? false
        }
        await handleTransport(transport, peer, isCurrent)
    }

    private func isCurrent(revision: UInt64, runtimeGeneration: UInt64) async -> Bool {
        guard desiredActive,
              lifecycleRevision == revision,
              let endpointServer else { return false }
        return await endpointServer.isCurrent(runtimeGeneration: runtimeGeneration)
    }

    private func requireCurrent(_ revision: UInt64) throws {
        guard desiredActive, lifecycleRevision == revision, !Task.isCancelled else {
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
        case .unavailable: configuration.cachedRelayCredential
        }
    }

    private static func isConnectivityFailure(_ error: any Error) -> Bool {
        guard let brokerError = error as? CmxIrohTrustBrokerClientError else {
            return false
        }
        return brokerError == .connectivity
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

    private func tearDownComponents(notify: Bool) async {
        supervisorEventTask?.cancel()
        supervisorEventTask = nil
        registrationRefreshTask?.cancel()
        registrationRefreshTask = nil
        await endpointServer?.stop()
        endpointServer = nil
        await relayCoordinator?.deactivate()
        relayCoordinator = nil
        await offlineSessions?.invalidate()
        offlineSessions = nil
        admissionController = nil
        let bindingID = localBinding?.bindingID
        localBinding = nil
        endpointAttestation = nil
        await supervisor?.deactivate()
        supervisor = nil
        if notify { await handleDeactivation(bindingID) }
    }
}
