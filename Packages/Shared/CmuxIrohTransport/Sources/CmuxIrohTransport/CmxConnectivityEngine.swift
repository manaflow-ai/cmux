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

    private let supervisor: CmxIrohEndpointSupervisor
    private let contextProvider: any CmxIrohClientContextProvider
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let authority: (any CmxConnectivityAuthorityServing)?
    private let installRouteSnapshot: RouteSnapshotInstaller?
    private var desiredActive = false
    private var lifecycleRevision: UInt64 = 0
    private var endpointGeneration: UInt64?
    private var localIdentity: CmxIrohPeerIdentity?
    private var routeRevision: UInt64?
    private var endpointEventTask: Task<Void, Never>?
    private var routeSyncOperation: RouteSyncOperation?
    private var peers: [CmxConnectivityPeerID: CmxConnectivityPeerSession] = [:]
    private var peerSnapshots: [CmxConnectivityPeerID: CmxConnectivityPeerSnapshot] = [:]
    private var observers: [UUID: AsyncStream<CmxConnectivityEngineSnapshot>.Continuation] = [:]
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
        installRouteSnapshot: RouteSnapshotInstaller? = nil
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
    }

    init(
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        authority: (any CmxConnectivityAuthorityServing)? = nil,
        installRouteSnapshot: RouteSnapshotInstaller? = nil
    ) {
        precondition((authority == nil) == (installRouteSnapshot == nil))
        self.supervisor = supervisor
        self.contextProvider = contextProvider
        self.protocolConfiguration = protocolConfiguration
        self.authority = authority
        self.installRouteSnapshot = installRouteSnapshot
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
        guard desiredActive, phase == .active else {
            throw CmxConnectivityEngineError.inactive
        }
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
        routeSyncOperation?.task.cancel()
        routeSyncOperation = nil
        await invalidateAllPeers(failure: .cancelled)
        await supervisor.deactivate()
        endpointGeneration = nil
        localIdentity = nil
        phase = .stopped
        publishSnapshot()
    }

    /// Records the last route revision installed atomically by the composition root.
    public func didInstallRouteRevision(_ revision: UInt64) {
        guard routeRevision != revision else { return }
        routeRevision = revision
        publishSnapshot()
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
        let peer = try activePeer(for: request)
        return try await peer.acquireControl(for: request, ownerID: ownerID)
    }

    func releaseControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let peer = peers[peerID] else {
            return
        }
        await peer.releaseControl(ownerID: ownerID)
    }

    func connectionContinuityID(
        for request: CmxByteTransportRequest
    ) async -> UInt64? {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let peer = peers[peerID] else {
            return nil
        }
        return await peer.connectionContinuityID()
    }

    func waitUntilConnectionCloses(
        for request: CmxByteTransportRequest
    ) async {
        guard let peerID = try? CmxConnectivityPeerID(request: request),
              let peer = peers[peerID] else {
            return
        }
        await peer.waitUntilCurrentConnectionCloses()
    }

    private func activePeer(
        for request: CmxByteTransportRequest
    ) throws -> CmxConnectivityPeerSession {
        guard desiredActive, phase == .active, endpointGeneration != nil else {
            throw CmxConnectivityEngineError.inactive
        }
        let peerID = try CmxConnectivityPeerID(request: request)
        if let peer = peers[peerID] {
            return peer
        }
        let supervisor = supervisor
        let contextProvider = contextProvider
        let protocolConfiguration = protocolConfiguration
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
                    protocolConfiguration: protocolConfiguration
                )
                do {
                    try await session.connect()
                    return session
                } catch {
                    await session.close()
                    throw error
                }
            },
            handleSnapshot: { [weak self] snapshot in
                await self?.peerDidChange(snapshot)
            }
        )
        peers[peerID] = peer
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
        guard desiredActive, case let .snapshot(endpoint) = event else { return }
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
                try await reconcileRoutes()
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
        if routeRevision != response.revision {
            await invalidateAllPeers(failure: .superseded)
            routeRevision = response.revision
            publishSnapshot()
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
            peers: peerSnapshots.values.sorted {
                if $0.peerID.deviceID == $1.peerID.deviceID {
                    return $0.peerID.identity.endpointID < $1.peerID.identity.endpointID
                }
                return $0.peerID.deviceID < $1.peerID.deviceID
            }
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
}
