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
    /// Durable paired-phone allowlist consulted for credential-less admission.
    /// `nil` disables allowlist admission entirely (fail closed).
    let pairedPeerAllowlist: CmxIrohPairedPeerAllowlist?
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
    let handleLANRefresh: LANRefreshHandler
    let handleLANPolicy: LANPolicyHandler

    var lifecycleRevision: UInt64 = 0
    var lifecyclePhase = LifecyclePhase.inactive
    var signOutOperation: Task<CmxIrohHostSignOutPreparation, Never>?
    var connectivityEngine: CmxConnectivityEngine?
    var endpointServer: CmxIrohEndpointServer?
    var admissionController: CmxIrohAdmissionController?
    var onlineAdmissionRegistry: CmxIrohOnlineAdmissionRegistry?
    var offlineSessions: CmxIrohOfflinePairingSessions?
    var connectivityEventTask: Task<Void, Never>?
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
        pairedPeerAllowlist: CmxIrohPairedPeerAllowlist? = nil,
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
        handleLANRefresh: @escaping LANRefreshHandler = {},
        handleLANPolicy: @escaping LANPolicyHandler = { _, _ in }
    ) {
        self.factory = factory
        self.broker = broker
        self.configuration = configuration
        self.pairedPeerAllowlist = pairedPeerAllowlist
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
        try await start(debugRelayOverride: CmxIrohDebugRelayOverride.activeProfile())
    }

    /// The injectable core of ``start()``.
    ///
    /// `debugRelayOverride` is the DEBUG-only forced relay, read once from
    /// the ``CmxIrohDebugRelayOverride`` funnel by the public entrypoint so
    /// tests can inject it deterministically.
    func start(
        debugRelayOverride: CmxIrohEndpointRelayProfile?
    ) async throws {
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
            // The debug-only forced relay wins over every stored or
            // configured profile, including the relay-less
            // `.unavailableManagedSelection` placeholder a host without a
            // verifiable cached policy is configured with. The override is a
            // custom profile, and custom relays are exempt from the
            // withhold-until-registered ordering below, so it stays installed
            // at bind and the endpoint dials the test relay immediately
            // without reintroducing the pre-registration managed-relay race.
            let endpointRelayProfile = try debugRelayOverride
                ?? currentEndpointRelayProfile
                ?? configuration.resolvedEndpointRelayProfile(
                    debugOverride: debugRelayOverride
                )
            currentEndpointRelayProfile = endpointRelayProfile
            // A verified cached policy proves the broker has acknowledged
            // this endpoint, so its relay dials pass the relay's allow hook
            // immediately and the profile stays installed at bind. Without
            // one the endpoint binds relay-less and the managed profile is
            // installed only after registration is acknowledged below,
            // ordering the first relay dial after broker admission (a denied
            // pre-registration dial is negatively cached by the relay).
            // Custom relays are user-operated and not admission-gated by the
            // cmux broker, so they stay installed at bind.
            let withholdsManagedRelaysUntilRegistered =
                withholdsManagedRelaysUntilRegistered(for: endpointRelayProfile)
            let endpointConfiguration = CmxIrohEndpointConfiguration(
                secretKey: configuration.identity.secretKey,
                alpns: [protocolConfiguration.alpn],
                bindPolicy: configuration.bindPolicy,
                relayProfile: withholdsManagedRelaysUntilRegistered
                    ? .unavailableManagedSelection
                    : endpointRelayProfile
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
            if withholdsManagedRelaysUntilRegistered {
                // The broker has now acknowledged this endpoint's binding: a
                // fresh host cannot leave resolveInitialPolicy otherwise,
                // because the cachedPolicy(after:) fallback requires the same
                // verified cached policy whose absence made this bind
                // withhold. Installing the managed relays only now guarantees
                // the first relay dial cannot race the relay's allow hook
                // into a negatively cached deny.
                try await connectivityEngine.replaceRelayProfile(
                    endpointRelayProfile,
                    expectedIdentity: endpointID
                )
                try requireCurrent(revision)
            }

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
                onlineRegistry: onlineAdmissionRegistry,
                allowlist: pairedPeerAllowlist,
                allowlistScope: pairedPeerAllowlist == nil
                    ? nil
                    : CmxIrohPairedPeerAllowlistScope(
                        accountID: configuration.accountID,
                        clientNamespace: configuration.clientNamespace,
                        appInstanceID: configuration.appInstanceID
                    )
            )
            self.offlineSessions = offlineSessions
            self.onlineAdmissionRegistry = onlineAdmissionRegistry
            self.admissionController = admissionController
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
            // Every path re-checks verified readiness immediately before
            // publication. Relay-required activations arrive here only after
            // the blocking waitForUsableHomeRelay() above succeeded, so the
            // check returns true for them without a second wait.
            let publishInline = await initialPublicationReady(
                engine: connectivityEngine
            )
            try requireCurrent(revision)
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
                // Every deferred first publication carries the pending flag so
                // any refresh round that ends up performing it re-checks
                // verified relay readiness first.
                initialPublicationPending = true
                if requiresRelayReadiness {
                    // Cached authority keeps offline admission and LAN
                    // discovery available, but it cannot describe this endpoint
                    // generation's live direct port. Give the lifecycle-owned
                    // retry loop the incomplete activation.
                    scheduleRegistrationRetry(
                        revision: revision,
                        retryAfterSeconds: publishedPolicy.registrationRetryAfterSeconds
                    )
                    // The retry loop owns the next broker round, but only the
                    // ready gate observes a relay that becomes usable without
                    // a network-change event. Arm it here too so a pending
                    // first publication always has a relay-readiness owner;
                    // it defers to the armed retry round when one exists.
                    scheduleInitialPublication(revision: revision)
                } else {
                    allowsReplacedBindingAdoption = cachedStartPolicy != nil
                    if let retryAfterSeconds = publishedPolicy
                        .registrationRetryAfterSeconds {
                        // A broker cooldown observed during activation keeps
                        // its validated floor for the next live round.
                        scheduleRegistrationRetry(
                            revision: revision,
                            retryAfterSeconds: retryAfterSeconds
                        )
                    } else if cachedStartPolicy != nil {
                        // Cached authority is verified against the live broker
                        // immediately, independent of relay readiness, so a
                        // server-side revocation or replacement cannot hide
                        // behind a relay outage. Readiness gates only the
                        // publication inside the refresh round.
                        scheduleRegistrationRefresh(revision: revision)
                    }
                    // The ready gate waits for a usable home relay and then
                    // runs the round that performs the deferred first
                    // publication with fresh path hints.
                    scheduleInitialPublication(revision: revision)
                }
            } else if registrationRefreshPending {
                registrationRefreshPending = false
                scheduleRegistrationRefresh(revision: revision)
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
    ///
    /// ROLLOUT NOTE (intended-shape attach reporting): this relay-readiness
    /// gate and the post-attach republish it defers exist so the Mac's own
    /// registration carries its relay route. The broker now also publishes
    /// the route server-side from the relay fleet's attach/detach reports
    /// (`POST /api/relay/report`, cmux-relay attach reporting), and
    /// discovery serves that server-observed hint ahead of client-published
    /// hints. The client republish stays as the fallback ONLY while fleet
    /// relays that do not report attach remain deployed; once the reporting
    /// relay build is rolled out fleet-wide, delete this gate and publish at
    /// register time.
    func initialPublicationReady(
        engine: CmxConnectivityEngine
    ) async -> Bool {
        if await engine.hasUsableHomeRelay() { return true }
        return !(await engine.hasConfiguredRelay())
    }

    func scheduleInitialPublication(revision: UInt64) {
        initialPublicationTask?.cancel()
        initialPublicationTask = Task { [weak self] in
            await self?.runInitialPublication(revision: revision)
        }
    }

    private func runInitialPublication(revision: UInt64) async {
        guard lifecyclePhase == .active,
              lifecycleRevision == revision,
              !Task.isCancelled else { return }
        guard let connectivityEngine else { return }
        if await connectivityEngine.hasConfiguredRelay() {
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
        guard initialPublicationPending else { return }
        guard registrationRefreshFailureCount == 0 else {
            // A broker cooldown or failure retry is already armed. That
            // lifecycle-owned round performs the deferred publication once it
            // succeeds, and it honors the broker's validated retry floor.
            return
        }
        scheduleRegistrationRefresh(revision: revision)
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
