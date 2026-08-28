public import CMUXMobileCore
import Foundation

/// Process-wide owner of one Iroh endpoint and one session actor per remote peer.
public actor CmxConnectivityEngine {
    /// Atomically installs one complete authoritative discovery snapshot.
    public typealias RouteSnapshotInstaller = @Sendable (
        _ snapshot: CmxIrohDiscoveryResponse
    ) async throws -> Void

    private struct RouteSyncOperation {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private struct EndpointReadinessOperation {
        let id: UUID
        let revision: UInt64
        let task: Task<Void, any Error>
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let contextProvider: (any CmxIrohClientContextProvider)?
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let authority: (any CmxConnectivityAuthorityServing)?
    private let installRouteSnapshot: RouteSnapshotInstaller?
    private let diagnosticLog: DiagnosticLog?
    private let clock: any CmxIrohRelayClock
    /// Deadline for each dial phase (public paths, private fallback, and the
    /// admission barrier) of every peer session this engine creates.
    private let dialPhaseTimeout: Duration
    private var desiredActive = false
    private var lifecycleRevision: UInt64 = 0
    private var endpointGeneration: UInt64?
    private var localIdentity: CmxIrohPeerIdentity?
    private var routeRevision: UInt64?
    private var routeContent: CmxConnectivityRouteContent?
    private var endpointEventTask: Task<Void, Never>?
    private var endpointReadinessOperation: EndpointReadinessOperation?
    private var routeSyncOperation: RouteSyncOperation?
    private var peers: [CmxConnectivityPeerID: CmxConnectivityPeerSession] = [:]
    private var peerSnapshots: [CmxConnectivityPeerID: CmxConnectivityPeerSnapshot] = [:]
    private var orderedPeerIDs: [CmxConnectivityPeerID] = []
    private var observers: [UUID: AsyncStream<CmxConnectivityEngineSnapshot>.Continuation] = [:]
    private var networkObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var phase = CmxConnectivityEngineSnapshot.Phase.stopped

    /// Creates a stopped engine with one stable endpoint identity.
    ///
    /// - Parameters:
    ///   - factory: The audited Iroh endpoint binding.
    ///   - endpointConfiguration: Stable secret key, ALPN, and relay profile.
    ///   - contextProvider: Current admission proof and route policy provider.
    ///   - protocolConfiguration: Application ALPN and lane limits.
    ///   - authority: Optional revisioned backend reconciliation boundary.
    ///   - installRouteSnapshot: Atomic policy installer paired with `authority`.
    public init(
        factory: any CmxIrohEndpointFactory,
        endpointConfiguration: CmxIrohEndpointConfiguration,
        contextProvider: any CmxIrohClientContextProvider,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        authority: (any CmxConnectivityAuthorityServing)? = nil,
        installRouteSnapshot: RouteSnapshotInstaller? = nil,
        diagnosticLog: DiagnosticLog? = nil,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        dialPhaseTimeout: Duration = .seconds(5)
    ) {
        precondition((authority == nil) == (installRouteSnapshot == nil))
        supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration
        )
        self.contextProvider = contextProvider
        self.protocolConfiguration = protocolConfiguration
        self.authority = authority
        self.installRouteSnapshot = installRouteSnapshot
        self.diagnosticLog = diagnosticLog
        self.clock = clock
        self.dialPhaseTimeout = dialPhaseTimeout
    }

    /// Creates a stopped endpoint-only engine for a host acceptor.
    public init(
        factory: any CmxIrohEndpointFactory,
        endpointConfiguration: CmxIrohEndpointConfiguration,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1
    ) {
        supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration
        )
        contextProvider = nil
        self.protocolConfiguration = protocolConfiguration
        authority = nil
        installRouteSnapshot = nil
        diagnosticLog = nil
        clock = CmxIrohSystemRelayClock()
        dialPhaseTimeout = .seconds(5)
    }

    init(
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        authority: (any CmxConnectivityAuthorityServing)? = nil,
        installRouteSnapshot: RouteSnapshotInstaller? = nil,
        diagnosticLog: DiagnosticLog? = nil,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        dialPhaseTimeout: Duration = .seconds(5)
    ) {
        precondition((authority == nil) == (installRouteSnapshot == nil))
        self.supervisor = supervisor
        self.contextProvider = contextProvider
        self.protocolConfiguration = protocolConfiguration
        self.authority = authority
        self.installRouteSnapshot = installRouteSnapshot
        self.diagnosticLog = diagnosticLog
        self.clock = clock
        self.dialPhaseTimeout = dialPhaseTimeout
    }

    /// Returns the current immutable UI-safe state.
    public func snapshot() -> CmxConnectivityEngineSnapshot {
        makeSnapshot()
    }

    /// Observes engine state beginning with the current snapshot.
    public func snapshots() -> AsyncStream<CmxConnectivityEngineSnapshot> {
        let observerID = UUID()
        let initial = makeSnapshot()
        return AsyncStream { continuation in
            observers[observerID] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    /// Observes endpoint network and recovery signals that require registration refresh.
    public func networkChanges() -> AsyncStream<Void> {
        let observerID = UUID()
        return AsyncStream { continuation in
            networkObservers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNetworkObserver(observerID) }
            }
        }
    }

    /// Creates an accept loop whose endpoint recovery is serialized by this engine.
    func makeEndpointServer(
        maximumPendingAdmissions: Int = 10,
        maximumPendingAdmissionsPerIdentity: Int = 1,
        maximumConnections: Int = 10,
        maximumConnectionsPerIdentity: Int = 2,
        admissionTimeout: TimeInterval = 15,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        handler: @escaping CmxIrohEndpointServer.ConnectionHandler
    ) -> CmxIrohEndpointServer {
        CmxIrohEndpointServer(
            supervisor: supervisor,
            maximumPendingAdmissions: maximumPendingAdmissions,
            maximumPendingAdmissionsPerIdentity: maximumPendingAdmissionsPerIdentity,
            maximumConnections: maximumConnections,
            maximumConnectionsPerIdentity: maximumConnectionsPerIdentity,
            admissionTimeout: admissionTimeout,
            clock: clock,
            recoverEndpoint: { [weak self] generation in
                guard let self else {
                    throw CmxConnectivityEngineError.inactive
                }
                return try await self.recoverEndpointForServer(
                    expectedGeneration: generation
                )
            },
            handler: handler
        )
    }

    /// Binds the process endpoint without creating a peer connection.
    public func start() async throws {
        guard phase == .stopped || phase == .failed else {
            if phase == .active { return }
            throw CmxConnectivityEngineError.superseded
        }
        desiredActive = true
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        phase = .starting
        publishSnapshot()
        observeEndpoint()
        do {
            let endpoint = try await supervisor.activate()
            guard desiredActive, lifecycleRevision == revision else {
                throw CmxConnectivityEngineError.superseded
            }
            try await installEndpoint(endpoint)
            try await reconcileRoutes()
            guard desiredActive, lifecycleRevision == revision else {
                throw CmxConnectivityEngineError.superseded
            }
            phase = .active
            publishSnapshot()
        } catch {
            guard desiredActive, lifecycleRevision == revision else {
                throw error
            }
            phase = .failed
            publishSnapshot()
            throw error
        }
    }

    /// Verifies the preserved endpoint after suspension and recreates it if stale.
    public func resume() async throws {
        guard desiredActive else {
            throw CmxConnectivityEngineError.inactive
        }
        try await ensureEndpointReady()
        let revision = lifecycleRevision
        let endpoint = try await supervisor.ensureHealthy()
        guard desiredActive, lifecycleRevision == revision else {
            throw CmxConnectivityEngineError.superseded
        }
        try await installEndpoint(endpoint)
        try await reconcileRoutes()
        guard desiredActive, lifecycleRevision == revision else {
            throw CmxConnectivityEngineError.superseded
        }
        phase = .active
        publishSnapshot()
    }

    /// Stops all peer sessions before closing the process endpoint.
    public func stop() async {
        guard phase != .stopped else { return }
        desiredActive = false
        lifecycleRevision &+= 1
        phase = .stopping
        publishSnapshot()
        endpointEventTask?.cancel()
        endpointEventTask = nil
        endpointReadinessOperation?.task.cancel()
        endpointReadinessOperation = nil
        routeSyncOperation?.task.cancel()
        routeSyncOperation = nil
        let stoppedNetworkObservers = networkObservers.values
        networkObservers.removeAll()
        for continuation in stoppedNetworkObservers {
            continuation.finish()
        }
        await invalidateAllPeers(failure: .cancelled)
        await supervisor.deactivate()
        endpointGeneration = nil
        localIdentity = nil
        phase = .stopped
        publishSnapshot()
    }

    /// Records the last route revision installed atomically by the composition root.
    ///
    /// Peers whose material route content is unchanged keep their live
    /// sessions; every other peer is invalidated before the new revision
    /// becomes visible. Account route revisions are monotonic, so an older
    /// completion of an overlapping reconciliation cannot roll back a newer
    /// installed revision or its content baseline.
    public func didInstallRouteRevision(
        _ revision: UInt64,
        routes: CmxIrohDiscoveryResponse
    ) async {
        if let routeRevision, revision < routeRevision { return }
        let content = CmxConnectivityRouteContent(snapshot: routes)
        guard routeRevision != revision else {
            // The recorded revision can lack a content baseline when a sync
            // stored it from an unchanged response without a snapshot. A
            // missing or differing baseline fails closed like any other
            // material change before the content becomes the baseline.
            if routeContent != content {
                await invalidatePeersSuperseded(by: content)
                routeContent = content
            }
            return
        }
        await invalidatePeersSuperseded(by: content)
        routeRevision = revision
        routeContent = content
        publishSnapshot()
    }

    /// Returns the exact active local endpoint identity.
    public func localEndpointIdentity() async throws -> CmxIrohPeerIdentity {
        try await ensureEndpointReady()
        let endpoint = try await supervisor.activeEndpoint()
        return await endpoint.identity()
    }

    /// Returns the active endpoint's public reachability snapshot.
    public func endpointAddress() async throws -> CmxIrohEndpointAddress {
        try await ensureEndpointReady()
        let endpoint = try await supervisor.activeEndpoint()
        return await endpoint.address()
    }

    /// Returns raw local direct addresses for authenticated registration only.
    public func localDirectAddresses() async throws -> [String] {
        try await ensureEndpointReady()
        let endpoint = try await supervisor.activeEndpoint()
        return await endpoint.localDirectAddresses()
    }

    /// Returns whether the active endpoint has a configured relay.
    public func hasConfiguredRelay() async -> Bool {
        await supervisor.hasConfiguredRelay()
    }

    /// Returns whether the active endpoint generation reports a usable home relay.
    public func hasUsableHomeRelay() async -> Bool {
        await supervisor.hasUsableHomeRelay()
    }

    /// Waits for the active endpoint generation to report relay readiness.
    public func waitForUsableHomeRelay(
        timeout: Duration = .seconds(15)
    ) async throws {
        try await ensureEndpointReady()
        try await supervisor.waitForUsableHomeRelay(timeout: timeout)
    }

    /// Replaces the endpoint relay profile before or after activation.
    public func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile
    ) async throws {
        try await supervisor.replaceRelayProfile(profile)
    }

    /// Replaces the active endpoint relay profile without changing identity.
    public func replaceRelayProfile(
        _ profile: CmxIrohEndpointRelayProfile,
        expectedIdentity: CmxIrohPeerIdentity
    ) async throws {
        try await supervisor.replaceRelayProfile(
            profile,
            expectedIdentity: expectedIdentity
        )
    }

    /// Returns the selected live path after removing raw coordinates.
    public func selectedTransportPath(
        relayPolicy: CmxIrohEffectiveRelayPolicy?
    ) async -> CmxIrohSelectedTransportPath {
        var selected: (
            peerID: CmxConnectivityPeerID,
            path: CmxIrohObservedConnectionPath
        )?
        for (peerID, peer) in peers {
            let candidate = await peer.observedSelectedPath()
            guard candidate != .unavailable else { continue }
            if let current = selected,
               !Self.pathSelectionPrecedes(
                   peerID,
                   snapshot: peerSnapshots[peerID],
                   current.peerID,
                   snapshot: peerSnapshots[current.peerID]
               ) {
                continue
            }
            selected = (peerID, candidate)
        }
        return CmxIrohSelectedTransportPathClassifier(policy: relayPolicy)
            .classify(selected?.path ?? .unavailable)
    }

    /// Emits when peer lifecycle or Iroh path selection can change path classification.
    public func selectedTransportPathChanges() -> AsyncStream<Void> {
        let snapshots = snapshots()
        return AsyncStream { continuation in
            let task = Task {
                for await _ in snapshots {
                    guard !Task.isCancelled else { return }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reconciles the last installed revision with the authoritative backend.
    ///
    /// Concurrent callers share one request. A changed revision becomes visible
    /// only after the complete replacement snapshot is installed.
    public func reconcileRoutes() async throws {
        guard let authority, let installRouteSnapshot else { return }
        guard desiredActive,
              phase == .starting || phase == .active else {
            throw CmxConnectivityEngineError.inactive
        }
        let revision = lifecycleRevision
        let operation: RouteSyncOperation
        if let routeSyncOperation {
            operation = routeSyncOperation
        } else {
            let operationID = UUID()
            let knownRevision = routeRevision
            let task = Task { [weak self] in
                guard let self else {
                    throw CmxConnectivityEngineError.inactive
                }
                try await self.performRouteSync(
                    authority: authority,
                    installRouteSnapshot: installRouteSnapshot,
                    knownRevision: knownRevision,
                    lifecycleRevision: revision
                )
            }
            operation = RouteSyncOperation(id: operationID, task: task)
            routeSyncOperation = operation
        }

        do {
            try await operation.task.value
            if routeSyncOperation?.id == operation.id {
                routeSyncOperation = nil
            }
        } catch {
            if routeSyncOperation?.id == operation.id {
                routeSyncOperation = nil
            }
            throw error
        }
    }

    /// Opens a terminal or artifact lane on the peer's sole admitted connection.
    public func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        try await ensureEndpointReady()
        let peer = try activePeer(for: request)
        return try await peer.openBidirectionalLane(
            for: request,
            lane: lane,
            priority: priority
        )
    }

    /// Returns the peer-owned server-event stream.
    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        try await ensureEndpointReady()
        let peer = try activePeer(for: request)
        return try await peer.serverEventByteStream(for: request)
    }

    /// Invalidates the exact peer connection. The next operation performs one fresh dial.
    public func invalidatePeer(
        for request: CmxByteTransportRequest,
        failure: DiagnosticFailureKind = .none
    ) async {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let peer = peers[peerID] else {
            return
        }
        await peer.invalidate(failure: failure)
    }

    func acquireControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async throws -> any CmxConnectivitySession {
        try await ensureEndpointReady()
        let peer = try activePeer(for: request)
        return try await peer.acquireControl(for: request, ownerID: ownerID)
    }

    func releaseControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID,
        reason: DiagnosticSessionLifecycleKind = .controlOwnerReleased,
        failure: DiagnosticFailureKind = .none
    ) async {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let peer = peers[peerID] else {
            return
        }
        await peer.releaseControl(
            ownerID: ownerID,
            reason: reason,
            failure: failure
        )
    }

    func updateControlPurpose(
        for request: CmxByteTransportRequest,
        ownerID: UUID,
        purpose: CmxTransportSessionPurpose
    ) async {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let peer = peers[peerID] else {
            return
        }
        await peer.updateControlPurpose(ownerID: ownerID, purpose: purpose)
    }

    /// Resolves the admitted session correlation for one exact peer request.
    /// This is intentionally a local query used only to link dial and session
    /// events after the shared peer actor has completed admission.
    func diagnosticSessionID(
        for request: CmxByteTransportRequest
    ) async -> Int? {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let peer = peers[peerID] else {
            return nil
        }
        return await peer.diagnosticSessionID()
    }

    private func activePeer(
        for request: CmxByteTransportRequest
    ) throws -> CmxConnectivityPeerSession {
        guard desiredActive,
              phase == .active,
              endpointGeneration != nil,
              let contextProvider else {
            throw CmxConnectivityEngineError.inactive
        }
        let peerID = try CmxConnectivityPeerID(request: request)
        if let peer = peers[peerID] {
            return peer
        }
        let supervisor = supervisor
        let protocolConfiguration = protocolConfiguration
        let diagnosticLog = diagnosticLog
        let clock = clock
        let dialPhaseTimeout = dialPhaseTimeout
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                let endpoint = try await supervisor.activeEndpoint()
                let context = try await contextProvider.context(for: request)
                let session = try CmxIrohClientSession(
                    endpoint: endpoint,
                    targetIdentity: peerID.identity,
                    dialPlan: context.dialPlan,
                    credential: context.credential,
                    privateFallbackAuthorization: context.privateFallbackAuthorization,
                    privateFallbackValidator: contextProvider,
                    privateFallbackContextProvider: {
                        try await contextProvider.contextWithPrivateFallback(
                            for: request,
                            basedOn: context
                        )
                    },
                    dialPhaseTimeout: dialPhaseTimeout,
                    protocolConfiguration: protocolConfiguration,
                    diagnostics: diagnosticLog
                )
                do {
                    try await session.connect()
                    return session
                } catch {
                    await session.close()
                    if !(Task.isCancelled || error is CancellationError) {
                        await contextProvider.noteDialFailure(
                            for: request,
                            dialPlan: context.dialPlan,
                            failure: DiagnosticFailureKind.classify(error)
                        )
                    }
                    throw error
                }
            },
            handleSnapshot: { [weak self] snapshot in
                await self?.peerDidChange(snapshot)
            },
            diagnosticLog: diagnosticLog,
            clock: clock
        )
        peers[peerID] = peer
        orderedPeerIDs.append(peerID)
        orderedPeerIDs.sort(by: Self.peerIDPrecedes)
        let initial = CmxConnectivityPeerSnapshot(
            peerID: peerID,
            phase: .disconnected,
            connectionGeneration: 0,
            stateRevision: 0,
            failure: .none,
            controlLaneOwned: false
        )
        peerSnapshots[peerID] = initial
        publishSnapshot()
        return peer
    }

    /// Waits for the desired-active endpoint to finish recovery before admitting
    /// endpoint consumers. The engine owns this barrier because it is the sole
    /// owner of both endpoint phase and the installed generation.
    private func ensureEndpointReady() async throws {
        try Task.checkCancellation()
        guard desiredActive else {
            throw CmxConnectivityEngineError.inactive
        }
        if phase == .active, endpointGeneration != nil { return }

        let revision = lifecycleRevision
        let operation: EndpointReadinessOperation
        if let current = endpointReadinessOperation,
           current.revision == revision {
            operation = current
        } else {
            endpointReadinessOperation?.task.cancel()
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else {
                    throw CmxConnectivityEngineError.inactive
                }
                try await self.performEndpointReadiness(revision: revision)
            }
            operation = EndpointReadinessOperation(
                id: id,
                revision: revision,
                task: task
            )
            endpointReadinessOperation = operation
        }

        do {
            try await operation.task.value
            if endpointReadinessOperation?.id == operation.id {
                endpointReadinessOperation = nil
            }
        } catch {
            if endpointReadinessOperation?.id == operation.id {
                endpointReadinessOperation = nil
            }
            throw error
        }

        try Task.checkCancellation()
        guard desiredActive,
              lifecycleRevision == revision,
              phase == .active,
              endpointGeneration != nil else {
            throw CmxConnectivityEngineError.superseded
        }
    }

    private func performEndpointReadiness(revision: UInt64) async throws {
        let endpoint = try await supervisor.activate()
        guard desiredActive, lifecycleRevision == revision else {
            throw CmxConnectivityEngineError.superseded
        }
        try await installEndpoint(endpoint)
        try await reconcileRoutesPreservingVerifiedPolicy()
        guard desiredActive, lifecycleRevision == revision else {
            throw CmxConnectivityEngineError.superseded
        }
        phase = .active
        publishSnapshot()
    }

    private func recoverEndpointForServer(
        expectedGeneration: UInt64
    ) async throws -> CmxIrohEndpointSnapshot {
        guard desiredActive else {
            throw CmxConnectivityEngineError.inactive
        }
        try await ensureEndpointReady()
        let revision = lifecycleRevision
        let endpoint = try await supervisor.ensureHealthy()
        guard desiredActive, lifecycleRevision == revision else {
            throw CmxConnectivityEngineError.superseded
        }
        guard endpoint.runtimeGeneration != expectedGeneration else {
            return endpoint
        }
        try await installEndpoint(endpoint)
        try await reconcileRoutes()
        guard desiredActive, lifecycleRevision == revision else {
            throw CmxConnectivityEngineError.superseded
        }
        phase = .active
        publishSnapshot()
        return endpoint
    }

    private func observeEndpoint() {
        guard endpointEventTask == nil else { return }
        let supervisor = supervisor
        endpointEventTask = Task { [weak self] in
            let events = await supervisor.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleEndpointEvent(event)
            }
        }
    }

    private func handleEndpointEvent(
        _ event: CmxIrohEndpointSupervisorEvent
    ) async {
        guard desiredActive else { return }
        switch event {
        case .networkChanged, .recovered:
            for continuation in networkObservers.values {
                continuation.yield()
            }
            return
        case let .snapshot(endpoint):
            await handleEndpointSnapshot(endpoint)
        }
    }

    private func handleEndpointSnapshot(
        _ endpoint: CmxIrohEndpointSnapshot
    ) async {
        switch endpoint.state {
        case .inactive:
            endpointGeneration = nil
            localIdentity = nil
            if phase == .active {
                await invalidateAllPeers(failure: .connectionClosed)
                phase = .failed
            }
            publishSnapshot()
        case .starting:
            phase = .starting
            publishSnapshot()
        case .active:
            do {
                try await installEndpoint(endpoint)
                if phase == .failed {
                    phase = .starting
                    publishSnapshot()
                }
                try await reconcileRoutesPreservingVerifiedPolicy()
                guard desiredActive else { return }
                phase = .active
                publishSnapshot()
            } catch {
                guard desiredActive else { return }
                phase = .failed
                publishSnapshot()
            }
        case .failed:
            await invalidateAllPeers(failure: .endpointUnavailable)
            endpointGeneration = nil
            localIdentity = nil
            phase = .failed
            publishSnapshot()
        }
    }

    private func reconcileRoutesPreservingVerifiedPolicy() async throws {
        do {
            try await reconcileRoutes()
        } catch {
            guard routeRevision != nil,
                  CmxIrohTrustBrokerClientError
                    .preservesVerifiedStateDuringRefresh(error) else {
                throw error
            }
        }
    }

    private func installEndpoint(
        _ endpoint: CmxIrohEndpointSnapshot
    ) async throws {
        guard endpoint.state == .active, let identity = endpoint.identity else {
            throw CmxConnectivityEngineError.inactive
        }
        if let endpointGeneration,
           endpointGeneration != endpoint.runtimeGeneration {
            await invalidateAllPeers(failure: .connectionClosed)
        }
        endpointGeneration = endpoint.runtimeGeneration
        localIdentity = identity
        publishSnapshot()
    }

    private func performRouteSync(
        authority: any CmxConnectivityAuthorityServing,
        installRouteSnapshot: RouteSnapshotInstaller,
        knownRevision: UInt64?,
        lifecycleRevision expectedLifecycleRevision: UInt64
    ) async throws {
        let response = try await authority.syncConnectivity(
            knownRevision: knownRevision
        )
        try Task.checkCancellation()
        guard desiredActive,
              lifecycleRevision == expectedLifecycleRevision else {
            throw CmxConnectivityEngineError.superseded
        }
        if response.changed {
            guard let snapshot = response.snapshot else {
                throw CmxIrohTrustBrokerClientError.invalidResponse
            }
            try await installRouteSnapshot(snapshot)
            try Task.checkCancellation()
            guard desiredActive,
                  lifecycleRevision == expectedLifecycleRevision else {
                throw CmxConnectivityEngineError.superseded
            }
        }
        let content = response.snapshot.map(CmxConnectivityRouteContent.init)
        if routeRevision != response.revision {
            await invalidatePeersSuperseded(by: content)
            routeRevision = response.revision
            routeContent = content
            publishSnapshot()
        } else if let content {
            routeContent = content
        }
    }

    /// Invalidates peers whose authoritative route material changed.
    ///
    /// A missing baseline or replacement fails closed and tears down every
    /// peer, preserving the pre-content-tracking behavior.
    private func invalidatePeersSuperseded(
        by content: CmxConnectivityRouteContent?
    ) async {
        guard let previous = routeContent,
              let content,
              previous.account == content.account else {
            await invalidateAllPeers(failure: .superseded)
            return
        }
        for (peerID, peer) in peers {
            guard let previousRoute = previous.peerRoute(for: peerID),
                  previousRoute == content.peerRoute(for: peerID) else {
                await peer.invalidate(failure: .superseded)
                continue
            }
        }
    }

    private func invalidateAllPeers(
        failure: DiagnosticFailureKind
    ) async {
        let activePeers = Array(peers.values)
        for peer in activePeers {
            await peer.invalidate(failure: failure)
        }
    }

    private func peerDidChange(_ snapshot: CmxConnectivityPeerSnapshot) {
        guard peers[snapshot.peerID] != nil else { return }
        guard snapshot.stateRevision
            >= (peerSnapshots[snapshot.peerID]?.stateRevision ?? 0) else {
            return
        }
        peerSnapshots[snapshot.peerID] = snapshot
        publishSnapshot()
    }

    private func makeSnapshot() -> CmxConnectivityEngineSnapshot {
        CmxConnectivityEngineSnapshot(
            phase: phase,
            endpointGeneration: endpointGeneration,
            localIdentity: localIdentity,
            routeRevision: routeRevision,
            peers: orderedPeerIDs.compactMap { peerSnapshots[$0] }
        )
    }

    private func publishSnapshot() {
        let snapshot = makeSnapshot()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func removeNetworkObserver(_ id: UUID) {
        networkObservers[id] = nil
    }

    private static func pathSelectionRank(
        _ snapshot: CmxConnectivityPeerSnapshot?
    ) -> Int {
        if snapshot?.controlPurpose == .foregroundControl { return 0 }
        if snapshot?.controlLaneOwned == true { return 1 }
        if snapshot?.phase == .connected { return 2 }
        return 3
    }

    private static func pathSelectionPrecedes(
        _ lhs: CmxConnectivityPeerID,
        snapshot left: CmxConnectivityPeerSnapshot?,
        _ rhs: CmxConnectivityPeerID,
        snapshot right: CmxConnectivityPeerSnapshot?
    ) -> Bool {
        let leftRank = pathSelectionRank(left)
        let rightRank = pathSelectionRank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        if left?.connectionGeneration != right?.connectionGeneration {
            return (left?.connectionGeneration ?? 0)
                > (right?.connectionGeneration ?? 0)
        }
        return peerIDPrecedes(lhs, rhs)
    }

    private static func peerIDPrecedes(
        _ lhs: CmxConnectivityPeerID,
        _ rhs: CmxConnectivityPeerID
    ) -> Bool {
        if lhs.deviceID == rhs.deviceID {
            return lhs.identity.endpointID < rhs.identity.endpointID
        }
        return lhs.deviceID < rhs.deviceID
    }
}
