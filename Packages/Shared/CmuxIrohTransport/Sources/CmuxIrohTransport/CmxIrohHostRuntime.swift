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
    public typealias RouteHandler = @Sendable (
        _ binding: CmxIrohBrokerBindingMetadata,
        _ pathHints: [CmxIrohPathHint]
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
        let routePathHints: [CmxIrohPathHint]
        let registrationRetryAfterSeconds: Int?
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
    /// One bounded signal-or-deadline window for the startup relay-readiness
    /// wait. A timeout keeps the endpoint unpublished and retries the wait.
    let relayReadinessTimeout: Duration
    let handleTransport: TransportHandler
    let handleBinding: BindingHandler
    let handleRoute: RouteHandler
    let handleDeactivation: DeactivationHandler
    let handleRelayCredential: RelayCredentialHandler
    let handleLANRefresh: LANRefreshHandler
    let handleLANPolicy: LANPolicyHandler

    var lifecycleRevision: UInt64 = 0
    var lifecyclePhase = LifecyclePhase.inactive
    var signOutOperation: Task<CmxIrohHostSignOutPreparation, Never>?
    var connectivityEngine: CmxConnectivityEngine?
    var relayCoordinator: CmxIrohRelayCredentialCoordinator?
    var endpointServer: CmxIrohEndpointServer?
    var admissionController: CmxIrohAdmissionController?
    var onlineAdmissionRegistry: CmxIrohOnlineAdmissionRegistry?
    var offlineSessions: CmxIrohOfflinePairingSessions?
    var connectivityEventTask: Task<Void, Never>?
    var relayActivationTask: Task<Void, Never>?
    var initialPublicationTask: Task<Void, Never>?
    /// True while activation still owes the first ready publication. It makes
    /// the next refresh round publish even when reachability is unchanged.
    var initialPublicationPending = false
    /// True only between a cache-first activation and its first completed live
    /// resolve, allowing that resolve to adopt a replaced broker binding in
    /// place instead of failing closed.
    var allowsReplacedBindingAdoption = false
    var lanPublicationTask: Task<Void, Never>?
    var lanPublicationGeneration: UInt64 = 0
    var registrationRefreshTask: Task<Void, Never>?
    var registrationRenewalTask: Task<Void, Never>?
    var registrationRefreshPending = false
    var registrationRefreshPendingForcesPublication = false
    var registrationRefreshEnabled = false
    var registrationRefreshFailureCount = 0
    var localBinding: CmxIrohBrokerBindingMetadata?
    var lastRegistrationRefreshState: CmxIrohRegistrationPublicationState?
    var managedRelayURLs: Set<String>
    var currentEndpointRelayProfile: CmxIrohEndpointRelayProfile?
    var endpointAttestation: CmxIrohEndpointAttestationResponse?
    var lanRendezvous: CmxIrohLANRendezvous?
    var authoritativeDiscovery: CmxIrohDiscoveryResponse?
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
        relayReadinessTimeout: Duration = .seconds(15),
        handleTransport: @escaping TransportHandler,
        handleBinding: @escaping BindingHandler = { _, _, _ in },
        handleRoute: @escaping RouteHandler = { _, _ in },
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
        self.relayReadinessTimeout = relayReadinessTimeout
        self.handleTransport = handleTransport
        self.handleBinding = handleBinding
        self.handleRoute = handleRoute
        self.handleDeactivation = handleDeactivation
        self.handleRelayCredential = handleRelayCredential
        self.handleLANRefresh = handleLANRefresh
        self.handleLANPolicy = handleLANPolicy
        managedRelayURLs = configuration.managedRelayURLs
        currentEndpointRelayProfile = configuration.endpointRelayProfile
    }


    /// Activates connectivity, restoring a verified cached policy immediately
    /// when one matches this binding, and reconciles authenticated broker
    /// policy in the background. Publication of the binding and route hints
    /// waits for a usable home relay so the Mac is never
    /// discoverable-but-undialable.
    public func start() async throws {
        guard lifecyclePhase.allowsStart else {
            throw CmxIrohHostRuntimeError.alreadyActive
        }
        lifecyclePhase = .starting
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        registrationRefreshPending = false
        registrationRefreshPendingForcesPublication = false
        registrationRefreshEnabled = false
        registrationRefreshFailureCount = 0
        initialPublicationPending = false
        allowsReplacedBindingAdoption = false
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
            let connectivityEngine = CmxConnectivityEngine(
                factory: factory,
                endpointConfiguration: endpointConfiguration,
                protocolConfiguration: protocolConfiguration
            )
            self.connectivityEngine = connectivityEngine
            await startConnectivityObservation(
                engine: connectivityEngine,
                revision: revision
            )
            try await connectivityEngine.start()
            try requireCurrent(revision)
            let endpointSnapshot = await connectivityEngine.snapshot()
            guard let endpointID = endpointSnapshot.localIdentity,
                  endpointSnapshot.endpointGeneration != nil else {
                throw CmxIrohHostRuntimeError.invalidLocalBinding
            }

            let requiresRelayReadiness = !protocolConfiguration
                .allowsNATTraversalAfterAdmission
            // A verified same-binding cached policy activates admission and
            // the endpoint immediately; the authenticated broker round then
            // runs in the background and reconciles. First launch (no cache),
            // an invalid cache, and relay-required debug hosts keep the
            // blocking resolve.
            let cachedStartPolicy = requiresRelayReadiness
                ? nil
                : validatedCachedStartPolicy(expectedEndpointID: endpointID)
            let policy: ResolvedPolicy
            if let cachedStartPolicy {
                policy = cachedStartPolicy
            } else {
                policy = try await resolveInitialPolicy(
                    engine: connectivityEngine,
                    expectedEndpointID: endpointID,
                    revision: revision
                )
            }
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
                    supervisor: connectivityEngine,
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

            let server = await connectivityEngine.makeEndpointServer { [weak self] connection, generation, markAdmitted in
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
                guard await connectivityEngine.hasConfiguredRelay() else {
                    throw CmxIrohEndpointSupervisorError.relayReadinessTimedOut
                }
                try await connectivityEngine.waitForUsableHomeRelay()
                try requireCurrent(revision)
                let readyPolicy = try await resolvePolicy(
                    engine: connectivityEngine,
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
            let publishInline: Bool
            if requiresRelayReadiness {
                publishInline = true
            } else {
                publishInline = await initialPublicationReady(
                    engine: connectivityEngine
                )
                try requireCurrent(revision)
            }
            let publishedFreshBinding: Bool
            if let registration = publishedPolicy.registration,
               let discovery = publishedPolicy.discovery,
               publishInline {
                await handleBinding(registration, discovery, publishedPolicy.attestation)
                try requireCurrent(revision)
                if let routeRevision = discovery.revision {
                    await connectivityEngine.didInstallRouteRevision(
                        routeRevision,
                        routes: discovery
                    )
                }
                scheduleRegistrationRenewal(
                    binding: registration.binding,
                    revision: revision
                )
                publishedFreshBinding = true
            } else {
                publishedFreshBinding = false
            }
            if publishedFreshBinding || publishedPolicy.registration == nil {
                // Fresh relay-ready hints, or a cached authority whose local
                // route identity is refreshed rather than unpublished. A live
                // policy without a usable home relay publishes nothing yet:
                // the Mac must not be discoverable-but-undialable.
                await handleRoute(
                    publishedPolicy.binding,
                    publishedPolicy.routePathHints
                )
                try requireCurrent(revision)
            }
            registrationRefreshEnabled = true
            if !publishedFreshBinding {
                registrationRefreshPending = false
                if requiresRelayReadiness {
                    // Cached authority keeps offline admission and LAN
                    // discovery available, but it cannot describe this endpoint
                    // generation's live direct port. Give the lifecycle-owned
                    // retry loop the incomplete activation.
                    scheduleRegistrationRetry(
                        revision: revision,
                        retryAfterSeconds: publishedPolicy.registrationRetryAfterSeconds
                    )
                } else {
                    // The ready gate activates the relay, waits for a usable
                    // home relay, and then runs the one live reconcile that
                    // publishes fresh path hints.
                    initialPublicationPending = true
                    allowsReplacedBindingAdoption = cachedStartPolicy != nil
                    scheduleInitialPublication(
                        binding: publishedPolicy.binding,
                        endpointID: endpointID,
                        bootstrap: publishedPolicy.relayBootstrap,
                        retryAfterSeconds: publishedPolicy.registrationRetryAfterSeconds,
                        revision: revision
                    )
                }
            } else if registrationRefreshPending {
                registrationRefreshPending = false
                scheduleRegistrationRefresh(revision: revision)
            }
            if let relayCoordinator, !requiresRelayReadiness, publishedFreshBinding {
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
                engine: connectivityEngine,
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
        markAdmitted: CmxIrohEndpointServer.AdmissionMarker
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
            ) { reason in
                let failure: DiagnosticFailureKind = switch reason {
                case .leaseExpired:
                    .admissionLeaseExpired
                case .denied:
                    .admissionDenied
                case .revalidationFailed:
                    .admissionRevalidationFailed
                }
                await session.close(failure: failure)
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
            CmxIrohAdmittedServerSession(
                peer: peer,
                session: session,
                promoteUsableSession: {
                    await markAdmitted.markUsable()
                }
            ),
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
        engine: CmxConnectivityEngine
    ) async {
        let context = CmxIrohHostLANAdvertisementContext(
            binding: binding,
            rendezvous: rendezvous
        )
        let directAddresses: LANDirectAddressProvider = {
            (try? await engine.localDirectAddresses()) ?? []
        }
        await handleLANPolicy(context, directAddresses)
    }

    /// Returns whether the binding may be published immediately: the home
    /// relay is already usable, or this endpoint will never own a relay.
    private func initialPublicationReady(
        engine: CmxConnectivityEngine
    ) async -> Bool {
        if await engine.hasUsableHomeRelay() { return true }
        guard relayCoordinator == nil else { return false }
        return !(await engine.hasConfiguredRelay())
    }

    func scheduleInitialPublication(
        binding: CmxIrohBrokerBindingMetadata,
        endpointID: CmxIrohPeerIdentity,
        bootstrap: CmxIrohRelayTokenResponse?,
        retryAfterSeconds: Int?,
        revision: UInt64
    ) {
        initialPublicationTask?.cancel()
        initialPublicationTask = Task { [weak self] in
            await self?.runInitialPublication(
                binding: binding,
                endpointID: endpointID,
                bootstrap: bootstrap,
                retryAfterSeconds: retryAfterSeconds,
                revision: revision
            )
        }
    }

    private func runInitialPublication(
        binding: CmxIrohBrokerBindingMetadata,
        endpointID: CmxIrohPeerIdentity,
        bootstrap: CmxIrohRelayTokenResponse?,
        retryAfterSeconds: Int?,
        revision: UInt64
    ) async {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              !Task.isCancelled else { return }
        if let coordinator = relayCoordinator {
            // Credential installation happens before the readiness wait so a
            // cached relay bootstrap makes the home relay usable without a
            // broker round. The coordinator owns bounded retry on failure.
            try? await coordinator.activate(
                bindingID: binding.bindingID,
                endpointIdentity: endpointID,
                bootstrap: bootstrap
            )
        }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              !Task.isCancelled else { return }
        guard let connectivityEngine else { return }
        let relayExpected: Bool
        if relayCoordinator != nil {
            relayExpected = true
        } else {
            relayExpected = await connectivityEngine.hasConfiguredRelay()
        }
        if relayExpected {
            // The Mac must never be discoverable-but-undialable: a readiness
            // timeout keeps the endpoint unpublished and retries the wait with
            // bounded backoff on the injected clock until a verified usable
            // relay path exists or this lifecycle revision is superseded.
            var readinessFailureCount = 0
            while true {
                guard lifecyclePhase == .active,
                      lifecycleRevision == revision,
                      !Task.isCancelled else { return }
                do {
                    try await connectivityEngine.waitForUsableHomeRelay(
                        timeout: relayReadinessTimeout
                    )
                    break
                } catch is CancellationError {
                    return
                } catch CmxIrohEndpointSupervisorError.relayReadinessTimedOut {
                    // Retry below after bounded backoff.
                } catch {
                    // The endpoint generation was replaced or deactivated. The
                    // successor lifecycle owns publication; this one stays
                    // unpublished and existing failure handling surfaces state.
                    return
                }
                guard lifecyclePhase == .active,
                      lifecycleRevision == revision,
                      !Task.isCancelled else { return }
                let delay = registrationRetrySchedule.delay(
                    failureCount: readinessFailureCount,
                    retryAfterSeconds: nil,
                    jitterUnitInterval: registrationRetryJitter()
                )
                readinessFailureCount = min(readinessFailureCount + 1, 20)
                do {
                    try await registrationClock.sleep(
                        until: registrationClock.now().addingTimeInterval(delay)
                    )
                } catch {
                    return
                }
            }
        }
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              !Task.isCancelled else { return }
        if let retryAfterSeconds {
            // A broker cooldown observed during activation keeps its validated
            // floor; the lifecycle retry loop owns the next live round.
            scheduleRegistrationRetry(
                revision: revision,
                retryAfterSeconds: retryAfterSeconds
            )
            return
        }
        guard initialPublicationPending else { return }
        scheduleRegistrationRefresh(revision: revision)
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
        engine: CmxConnectivityEngine,
        revision: UInt64
    ) {
        lanPublicationGeneration &+= 1
        let generation = lanPublicationGeneration
        lanPublicationTask?.cancel()
        lanPublicationTask = Task { [weak self] in
            await self?.publishLANSidecar(
                binding: binding,
                rendezvous: rendezvous,
                engine: engine,
                revision: revision,
                generation: generation
            )
        }
    }

    private func publishLANSidecar(
        binding: CmxIrohBrokerBindingMetadata,
        rendezvous: CmxIrohLANRendezvous,
        engine: CmxConnectivityEngine,
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
            engine: engine
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

}
