import CMUXMobileCore
import Foundation

/// Sole owner of dialing, admission, lanes, closure, and redial for one peer.
actor CmxConnectivityPeerSession {
    typealias SessionBuilder = @Sendable (
        _ request: CmxByteTransportRequest
    ) async throws -> any CmxConnectivitySession
    typealias SnapshotHandler = @Sendable (
        _ snapshot: CmxConnectivityPeerSnapshot
    ) async -> Void

    private struct PendingConnection {
        let id: UUID
        let task: Task<any CmxConnectivitySession, any Error>
    }

    private struct ActiveConnection {
        let id: UUID
        let session: any CmxConnectivitySession
        let closureTask: Task<Void, Never>
    }

    let peerID: CmxConnectivityPeerID
    private let buildSession: SessionBuilder
    private let handleSnapshot: SnapshotHandler
    private var lifecycleRevision: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var stateRevision: UInt64 = 0
    private var pendingConnection: PendingConnection?
    private var activeConnection: ActiveConnection?
    private var controlOwner: UUID?
    private var failure = DiagnosticFailureKind.none

    init(
        peerID: CmxConnectivityPeerID,
        buildSession: @escaping SessionBuilder,
        handleSnapshot: @escaping SnapshotHandler = { _ in }
    ) {
        self.peerID = peerID
        self.buildSession = buildSession
        self.handleSnapshot = handleSnapshot
    }

    func snapshot() -> CmxConnectivityPeerSnapshot {
        makeSnapshot()
    }

    func acquireControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async throws -> any CmxConnectivitySession {
        try requirePeer(request)
        guard controlOwner == nil || controlOwner == ownerID else {
            throw CmxIrohByteTransportError.controlLaneAlreadyOwned
        }
        controlOwner = ownerID
        publishSnapshot()
        do {
            return try await connectedSession(for: request)
        } catch {
            if controlOwner == ownerID {
                controlOwner = nil
                publishSnapshot()
            }
            throw error
        }
    }

    func releaseControl(ownerID: UUID) async {
        guard controlOwner == ownerID else { return }
        controlOwner = nil
        await invalidate(failure: .none)
    }

    func connectedSession(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxConnectivitySession {
        try requirePeer(request)
        if let activeConnection {
            if !(await activeConnection.session.isClosed()) {
                return activeConnection.session
            }
            await removeActiveConnection(
                matching: activeConnection.id,
                failure: .connectionClosed
            )
        }

        let revision = lifecycleRevision
        let pending: PendingConnection
        if let pendingConnection {
            pending = pendingConnection
        } else {
            connectionGeneration &+= 1
            failure = .none
            let buildSession = buildSession
            let task = Task {
                try Task.checkCancellation()
                let session = try await buildSession(request)
                guard !Task.isCancelled else {
                    await session.close()
                    throw CancellationError()
                }
                return session
            }
            pending = PendingConnection(id: UUID(), task: task)
            pendingConnection = pending
            publishSnapshot()
        }

        do {
            let connected = try await pending.task.value
            guard lifecycleRevision == revision else {
                await connected.close()
                throw CmxConnectivityEngineError.superseded
            }
            if let installed = activeConnection {
                if installed.id != pending.id {
                    await connected.close()
                }
                return installed.session
            }
            if await connected.isClosed() {
                await connected.close()
                throw CmxIrohClientSessionError.alreadyClosed
            }
            if pendingConnection?.id == pending.id {
                pendingConnection = nil
            }
            let connectionID = pending.id
            let closureTask = Task { [weak self] in
                await connected.waitUntilClosed()
                guard !Task.isCancelled else { return }
                let attribution = await connected.closeAttribution()
                await self?.connectionDidClose(
                    id: connectionID,
                    failure: attribution.failureKind
                )
            }
            activeConnection = ActiveConnection(
                id: connectionID,
                session: connected,
                closureTask: closureTask
            )
            failure = .none
            publishSnapshot()
            return connected
        } catch {
            if pendingConnection?.id == pending.id {
                pendingConnection = nil
                failure = DiagnosticFailureKind.classify(error)
                publishSnapshot()
            }
            throw error
        }
    }

    func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        let session = try await connectedSession(for: request)
        do {
            return try await session.openBidirectionalLane(lane, priority: priority)
        } catch {
            await invalidate(failure: DiagnosticFailureKind.classify(error))
            throw error
        }
    }

    func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let session = try await connectedSession(for: request)
        do {
            return try await session.serverEventByteStream()
        } catch {
            await invalidate(failure: DiagnosticFailureKind.classify(error))
            throw error
        }
    }

    func connectionContinuityID() async -> UInt64? {
        await activeConnection?.session.connectionContinuityID()
    }

    func waitUntilCurrentConnectionCloses() async {
        await activeConnection?.session.waitUntilClosed()
    }

    func invalidate(failure: DiagnosticFailureKind = .none) async {
        lifecycleRevision &+= 1
        pendingConnection?.task.cancel()
        pendingConnection = nil
        let closing = activeConnection
        activeConnection = nil
        closing?.closureTask.cancel()
        controlOwner = nil
        self.failure = failure
        publishSnapshot()
        await closing?.session.close()
    }

    private func connectionDidClose(
        id: UUID,
        failure: DiagnosticFailureKind
    ) {
        guard activeConnection?.id == id else { return }
        activeConnection?.closureTask.cancel()
        activeConnection = nil
        controlOwner = nil
        self.failure = failure
        publishSnapshot()
    }

    private func removeActiveConnection(
        matching id: UUID,
        failure: DiagnosticFailureKind
    ) async {
        guard let activeConnection, activeConnection.id == id else { return }
        self.activeConnection = nil
        activeConnection.closureTask.cancel()
        controlOwner = nil
        self.failure = failure
        publishSnapshot()
        await activeConnection.session.close()
    }

    private func requirePeer(_ request: CmxByteTransportRequest) throws {
        guard try CmxConnectivityPeerID(request: request) == peerID else {
            throw CmxConnectivityEngineError.peerIntentMismatch
        }
    }

    private func makeSnapshot() -> CmxConnectivityPeerSnapshot {
        let phase: CmxConnectivityPeerSnapshot.Phase
        if activeConnection != nil {
            phase = .connected
        } else if pendingConnection != nil {
            phase = .connecting
        } else if failure == .none {
            phase = .disconnected
        } else {
            phase = .failed
        }
        return CmxConnectivityPeerSnapshot(
            peerID: peerID,
            phase: phase,
            connectionGeneration: connectionGeneration,
            stateRevision: stateRevision,
            failure: failure,
            controlLaneOwned: controlOwner != nil
        )
    }

    private func publishSnapshot() {
        stateRevision &+= 1
        let snapshot = makeSnapshot()
        let handleSnapshot = handleSnapshot
        Task {
            await handleSnapshot(snapshot)
        }
    }
}
