import CMUXMobileCore
import Foundation

/// Sole owner of dialing, admission, lanes, closure, and redial for one peer.
actor CmxConnectivityPeerSession {
    typealias LegacySessionBuilder = @Sendable (
        _ request: CmxByteTransportRequest
    ) async throws -> any CmxConnectivitySession
    typealias SessionBuilder = @Sendable (
        _ request: CmxByteTransportRequest,
        _ retirement: CmxConnectivityPendingSessionRetirement
    ) async throws -> any CmxConnectivitySession
    typealias SnapshotHandler = @Sendable (
        _ snapshot: CmxConnectivityPeerSnapshot
    ) async -> Void

    private struct PendingConnection {
        let id: UUID
        let diagnosticID: Int
        let purpose: CmxTransportSessionPurpose
        let task: Task<any CmxConnectivitySession, any Error>
        let retirement: CmxConnectivityPendingSessionRetirement
    }

    private struct ActiveConnection {
        let id: UUID
        let diagnosticID: Int
        let initialPurpose: CmxTransportSessionPurpose
        let session: any CmxConnectivitySession
        var closureTask: Task<Void, Never>?
        var pathObservationTask: Task<Void, Never>?
        var pathEventObservationTask: Task<Void, Never>?
    }

    private struct ControlOwner {
        let id: UUID
        let purpose: CmxTransportSessionPurpose
    }

    private struct ControlWaiter {
        let id: UUID
        let ownerID: UUID
        let purpose: CmxTransportSessionPurpose
        let continuation: CheckedContinuation<Void, Never>
    }

    let peerID: CmxConnectivityPeerID
    private let buildSession: SessionBuilder
    private let handleSnapshot: SnapshotHandler
    private let diagnosticLog: DiagnosticLog?
    private var lifecycleRevision: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var stateRevision: UInt64 = 0
    private var nextDiagnosticSessionID = 0
    private var pendingConnection: PendingConnection?
    private var retiredDialDrains: [UUID: Task<Void, Never>] = [:]
    private var retiredConnectionCleanups: [UUID: Task<Void, Never>] = [:]
    private var activeConnection: ActiveConnection?
    private var controlOwner: ControlOwner?
    private var controlWaiters: [ControlWaiter] = []
    private var failure = DiagnosticFailureKind.none

    init(
        peerID: CmxConnectivityPeerID,
        buildSession: @escaping LegacySessionBuilder,
        handleSnapshot: @escaping SnapshotHandler = { _ in },
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.peerID = peerID
        self.buildSession = { request, _ in
            try await buildSession(request)
        }
        self.handleSnapshot = handleSnapshot
        self.diagnosticLog = diagnosticLog
    }

    init(
        peerID: CmxConnectivityPeerID,
        buildRetirableSession: @escaping SessionBuilder,
        handleSnapshot: @escaping SnapshotHandler = { _ in },
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.peerID = peerID
        buildSession = buildRetirableSession
        self.handleSnapshot = handleSnapshot
        self.diagnosticLog = diagnosticLog
    }

    func snapshot() -> CmxConnectivityPeerSnapshot {
        makeSnapshot()
    }

    func acquireControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async throws -> any CmxConnectivitySession {
        try requirePeer(request)
        try await reserveControlOwner(
            ownerID: ownerID,
            purpose: request.sessionPurpose
        )
        do {
            return try await connectedSession(
                for: request,
                preservesControlOwnerOnClosed: true
            )
        } catch {
            if controlOwner?.id == ownerID {
                releaseControlOwner(ownerID: ownerID)
            }
            throw error
        }
    }

    func releaseControl(
        ownerID: UUID,
        reason: DiagnosticSessionLifecycleKind = .controlOwnerReleased,
        failure: DiagnosticFailureKind = .none
    ) async {
        guard controlOwner?.id == ownerID else { return }
        lifecycleRevision &+= 1
        let retiredPending = await retirePendingConnection()
        await closeActiveConnection(
            releasesControlOwner: true,
            reason: reason,
            failure: failure
        )
        if controlOwner?.id == ownerID {
            releaseControlOwner(ownerID: ownerID)
            if let retiredPending {
                recordSessionLifecycle(
                    .controlOwnerReleased,
                    sessionID: retiredPending.diagnosticID,
                    purpose: retiredPending.purpose
                )
            }
        }
    }

    func updateControlPurpose(
        ownerID: UUID,
        purpose: CmxTransportSessionPurpose
    ) {
        guard controlOwner?.id == ownerID else { return }
        controlOwner = ControlOwner(id: ownerID, purpose: purpose)
        publishSnapshot()
    }

    func connectedSession(
        for request: CmxByteTransportRequest,
        preservesControlOwnerOnClosed: Bool = false
    ) async throws -> any CmxConnectivitySession {
        try requirePeer(request)
        var corpseRetriesRemaining = 1

        redial: while true {
            if let activeConnection {
                let activeRevision = lifecycleRevision
                let activeWasClosed = await activeConnection.session.isClosed()
                guard lifecycleRevision == activeRevision,
                      self.activeConnection?.id == activeConnection.id else {
                    continue redial
                }
                if !activeWasClosed {
                    return activeConnection.session
                }
                await removeActiveConnection(
                    matching: activeConnection.id,
                    releasesControlOwner: !preservesControlOwnerOnClosed,
                    reason: .closedSessionEvicted,
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
                let retirement = CmxConnectivityPendingSessionRetirement()
                let diagnosticID = makeDiagnosticSessionID()
                let task = Task {
                    try Task.checkCancellation()
                    let session = try await buildSession(request, retirement)
                    guard !Task.isCancelled else {
                        await session.close()
                        throw CancellationError()
                    }
                    return session
                }
                pending = PendingConnection(
                    id: UUID(),
                    diagnosticID: diagnosticID,
                    purpose: request.sessionPurpose,
                    task: task,
                    retirement: retirement
                )
                pendingConnection = pending
                recordSessionLifecycle(
                    .replacementDialStarted,
                    sessionID: diagnosticID,
                    purpose: request.sessionPurpose
                )
                publishSnapshot()
            }

            let connected: any CmxConnectivitySession
            do {
                connected = try await pending.task.value
                guard lifecycleRevision == revision else {
                    await connected.close()
                    throw CmxConnectivityEngineError.superseded
                }
            } catch {
                if pendingConnection?.id == pending.id {
                    pendingConnection = nil
                    failure = DiagnosticFailureKind.classify(error)
                    publishSnapshot()
                }
                throw error
            }

            if let installed = activeConnection {
                if installed.id == pending.id {
                    await pending.retirement.finish()
                    if pendingConnection?.id == pending.id {
                        pendingConnection = nil
                    }
                    guard lifecycleRevision == revision,
                          activeConnection?.id == pending.id else {
                        await connected.close()
                        throw CmxConnectivityEngineError.superseded
                    }
                    return installed.session
                }
                let winner = await settleRedundantDial(
                    connected,
                    installedID: installed.id
                )
                await pending.retirement.finish()
                if pendingConnection?.id == pending.id {
                    pendingConnection = nil
                }
                guard lifecycleRevision == revision else {
                    await connected.close()
                    throw CmxConnectivityEngineError.superseded
                }
                if let winner {
                    return winner
                }
                continue redial
            }
            let connectedWasClosed = await connected.isClosed()
            guard lifecycleRevision == revision else {
                await connected.close()
                throw CmxConnectivityEngineError.superseded
            }
            if connectedWasClosed {
                await connected.close()
                await pending.retirement.finish()
                if pendingConnection?.id == pending.id {
                    pendingConnection = nil
                }
                guard lifecycleRevision == revision else {
                    throw CmxConnectivityEngineError.superseded
                }
                guard corpseRetriesRemaining > 0 else {
                    throw CmxIrohClientSessionError.alreadyClosed
                }
                corpseRetriesRemaining -= 1
                continue redial
            }

            // The dead-on-arrival probe suspends this actor. A concurrent
            // caller that dialed in that window may have installed first;
            // installing over it would leak its session and double-record
            // an established lifecycle for the same peer.
            if let installed = activeConnection {
                if installed.id == pending.id {
                    await pending.retirement.finish()
                    if pendingConnection?.id == pending.id {
                        pendingConnection = nil
                    }
                    guard lifecycleRevision == revision,
                          activeConnection?.id == pending.id else {
                        await connected.close()
                        throw CmxConnectivityEngineError.superseded
                    }
                    return installed.session
                }
                let winner = await settleRedundantDial(
                    connected,
                    installedID: installed.id
                )
                await pending.retirement.finish()
                if pendingConnection?.id == pending.id {
                    pendingConnection = nil
                }
                guard lifecycleRevision == revision else {
                    await connected.close()
                    throw CmxConnectivityEngineError.superseded
                }
                if let winner {
                    return winner
                }
                continue redial
            }
            guard pendingConnection?.id == pending.id else {
                await connected.close()
                throw CmxConnectivityEngineError.superseded
            }
            // Install synchronously before clearing the pending retirement
            // handle. A concurrent release therefore sees either a pending
            // candidate or an active connection, and always closes its parent
            // before relinquishing the control owner.
            pendingConnection = nil
            install(
                connected,
                id: pending.id,
                diagnosticID: pending.diagnosticID,
                purpose: request.sessionPurpose
            )
            await pending.retirement.finish()
            guard lifecycleRevision == revision,
                  activeConnection?.id == pending.id else {
                await connected.close()
                throw CmxConnectivityEngineError.superseded
            }
            return activeConnection?.session ?? connected
        }
    }

    func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        try requirePeer(request)
        guard controlOwner != nil, let activeConnection else {
            throw CmxConnectivityEngineError.inactive
        }
        let session = activeConnection.session
        let connectionID = activeConnection.id
        guard !(await session.isClosed()),
              self.activeConnection?.id == connectionID,
              controlOwner != nil else {
            await removeActiveConnection(
                matching: connectionID,
                releasesControlOwner: true,
                reason: .applicationLaneFailed,
                failure: .connectionClosed
            )
            throw CmxConnectivityEngineError.inactive
        }
        do {
            let stream = try await session.openBidirectionalLane(
                lane,
                priority: priority
            )
            guard self.activeConnection?.id == connectionID,
                  controlOwner != nil else {
                await stream.sendStream.reset(errorCode: 1)
                await stream.receiveStream.stop(errorCode: 1)
                throw CmxConnectivityEngineError.superseded
            }
            return stream
        } catch {
            try Task.checkCancellation()
            guard await session.isClosed() else { throw error }
            await removeActiveConnection(
                matching: connectionID,
                releasesControlOwner: true,
                reason: .applicationLaneFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        try requirePeer(request)
        guard controlOwner != nil, let activeConnection else {
            throw CmxConnectivityEngineError.inactive
        }
        let connectionID = activeConnection.id
        let stream = try await activeConnection.session.serverEventByteStream()
        guard self.activeConnection?.id == connectionID,
              controlOwner != nil else {
            let drain = Task {
                do {
                    for try await _ in stream {}
                } catch {}
            }
            drain.cancel()
            throw CmxConnectivityEngineError.superseded
        }
        return stream
    }

    func connectionContinuityID() async -> UInt64? {
        await activeConnection?.session.connectionContinuityID()
    }

    func observedSelectedPath() async -> CmxIrohObservedConnectionPath {
        guard let activeConnection else { return .unavailable }
        return await activeConnection.session.observedSelectedPath()
    }

    func waitUntilCurrentConnectionCloses() async {
        await activeConnection?.session.waitUntilClosed()
    }

    func invalidate(failure: DiagnosticFailureKind = .none) async {
        lifecycleRevision &+= 1
        _ = await retirePendingConnection()
        await closeActiveConnection(
            releasesControlOwner: false,
            reason: .runtimeReconfigured,
            failure: failure
        )
        cancelControlOwnership()
        self.failure = failure
        publishSnapshot()
    }

    /// Closes a redundant dial that lost to an installed winner.
    ///
    /// Closing suspends this actor, so the winner can be invalidated,
    /// replaced, or remotely closed before the close settles. Only a
    /// still-installed live winner may be handed out; a nil result means
    /// the caller must redial.
    private func settleRedundantDial(
        _ connected: any CmxConnectivitySession,
        installedID: UUID
    ) async -> (any CmxConnectivitySession)? {
        await connected.close()
        guard let current = activeConnection,
              current.id == installedID,
              !(await current.session.isClosed()) else {
            return nil
        }
        return current.session
    }

    private func install(
        _ connected: any CmxConnectivitySession,
        id: UUID,
        diagnosticID: Int,
        purpose: CmxTransportSessionPurpose
    ) {
        // Publish ownership before starting streams whose first value is an
        // immediate snapshot. Otherwise an already-pathless connection can
        // notify before the actor has an entry to evict, losing the only
        // terminal usability signal.
        activeConnection = ActiveConnection(
            id: id,
            diagnosticID: diagnosticID,
            initialPurpose: purpose,
            session: connected,
            closureTask: nil,
            pathObservationTask: nil,
            pathEventObservationTask: nil
        )
        let closureTask = Task { [weak self] in
            await connected.waitUntilClosed()
            guard !Task.isCancelled else { return }
            await self?.connectionDidClose(
                id: id,
                failure: .connectionClosed
            )
        }
        let pathObservationTask = Task { [weak self] in
            let changes = await connected.observedSelectedPathChanges()
            for await path in changes {
                guard !Task.isCancelled else { return }
                await self?.pathDidChange(id: id, path: path)
            }
        }
        let pathEventObservationTask: Task<Void, Never>?
        if let diagnosticLog {
            let recorder = CmxIrohConnectionDiagnosticRecorder(
                diagnosticLog: diagnosticLog,
                sessionID: diagnosticID
            )
            pathEventObservationTask = Task {
                let events = await connected.observedPathEvents()
                for await event in events {
                    guard !Task.isCancelled else { return }
                    recorder.record(event)
                }
            }
        } else {
            pathEventObservationTask = nil
        }
        guard var installed = activeConnection, installed.id == id else {
            closureTask.cancel()
            pathObservationTask.cancel()
            pathEventObservationTask?.cancel()
            return
        }
        installed.closureTask = closureTask
        installed.pathObservationTask = pathObservationTask
        installed.pathEventObservationTask = pathEventObservationTask
        activeConnection = installed
        failure = .none
        recordSessionLifecycle(
            .established,
            sessionID: diagnosticID,
            purpose: controlOwner?.purpose ?? purpose
        )
        publishSnapshot()
    }

    private func connectionDidClose(
        id: UUID,
        failure: DiagnosticFailureKind
    ) async {
        guard let activeConnection, activeConnection.id == id else { return }
        self.activeConnection = nil
        let removedOwner = controlOwner
        let closurePurpose = removedOwner?.purpose
            ?? activeConnection.initialPurpose
        activeConnection.closureTask?.cancel()
        activeConnection.pathObservationTask?.cancel()
        activeConnection.pathEventObservationTask?.cancel()
        recordSessionLifecycle(
            .remoteClosed,
            sessionID: activeConnection.diagnosticID,
            purpose: closurePurpose
        )
        if self.activeConnection == nil,
           pendingConnection == nil,
           let owner = removedOwner {
            releaseControlOwner(ownerID: owner.id)
            recordSessionLifecycle(
                .controlOwnerReleased,
                sessionID: activeConnection.diagnosticID,
                purpose: closurePurpose
            )
        }
        // Precise remote-close attribution is post-close cleanup. Keep this
        // peer disconnected until it arrives so a generic placeholder cannot
        // win the failed snapshot ahead of the real reason.
        self.failure = .none
        publishSnapshot()
        startRetiredConnectionCleanup(
            active: activeConnection,
            failure: failure,
            purpose: closurePurpose,
            publishesAttributedFailure: true
        )
    }

    private func removeActiveConnection(
        matching id: UUID?,
        releasesControlOwner: Bool,
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        guard let activeConnection,
              id == nil || activeConnection.id == id else { return }
        self.activeConnection = nil
        let removedOwner = controlOwner
        let closurePurpose = removedOwner?.purpose
            ?? activeConnection.initialPurpose
        activeConnection.closureTask?.cancel()
        activeConnection.pathObservationTask?.cancel()
        activeConnection.pathEventObservationTask?.cancel()
        self.failure = failure
        publishSnapshot()

        // `close()` acknowledges parent-connection close. Child stream resets,
        // watcher joins, attribution, and diagnostics are a separate receipt.
        recordSessionLifecycle(
            .retirementStarted,
            sessionID: activeConnection.diagnosticID,
            purpose: closurePurpose
        )
        if reason != .controlOwnerReleased {
            recordSessionLifecycle(
                reason,
                sessionID: activeConnection.diagnosticID,
                purpose: closurePurpose
            )
        }
        await activeConnection.session.close()
        recordSessionLifecycle(
            .parentCloseAcknowledged,
            sessionID: activeConnection.diagnosticID,
            purpose: closurePurpose
        )
        if releasesControlOwner,
           self.activeConnection == nil,
           pendingConnection == nil,
           let owner = removedOwner {
            releaseControlOwner(ownerID: owner.id)
            recordSessionLifecycle(
                .controlOwnerReleased,
                sessionID: activeConnection.diagnosticID,
                purpose: closurePurpose
            )
        }
        startRetiredConnectionCleanup(
            active: activeConnection,
            failure: failure,
            purpose: closurePurpose,
            publishesAttributedFailure: false
        )
    }

    private func closeActiveConnection(
        releasesControlOwner: Bool,
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        await removeActiveConnection(
            matching: nil,
            releasesControlOwner: releasesControlOwner,
            reason: reason,
            failure: failure
        )
    }

    private func retirePendingConnection() async -> PendingConnection? {
        guard let pending = pendingConnection else { return nil }
        pendingConnection = nil
        pending.task.cancel()
        recordSessionLifecycle(
            .retirementStarted,
            sessionID: pending.diagnosticID,
            purpose: pending.purpose
        )
        await pending.retirement.retire()
        recordSessionLifecycle(
            .parentCloseAcknowledged,
            sessionID: pending.diagnosticID,
            purpose: pending.purpose
        )
        let drainID = UUID()
        retiredDialDrains[drainID] = Task { [weak self] in
            let orphan = try? await pending.task.value
            if let self {
                await self.settleRetiredDial(id: drainID, orphan: orphan)
            } else if let orphan {
                await orphan.close()
            }
        }
        return pending
    }

    private func settleRetiredDial(
        id: UUID,
        orphan: (any CmxConnectivitySession)?
    ) async {
        if let orphan {
            await orphan.close()
        }
        retiredDialDrains[id] = nil
    }

    private func startRetiredConnectionCleanup(
        active: ActiveConnection,
        failure: DiagnosticFailureKind,
        purpose: CmxTransportSessionPurpose,
        publishesAttributedFailure: Bool
    ) {
        let cleanupID = UUID()
        retiredConnectionCleanups[cleanupID] = Task { [weak self] in
            await active.session.waitForPostCloseCleanup()
            await active.pathEventObservationTask?.value
            await self?.finishRetiredConnectionCleanup(
                cleanupID: cleanupID,
                active: active,
                failure: failure,
                purpose: purpose,
                publishesAttributedFailure: publishesAttributedFailure
            )
        }
    }

    private func finishRetiredConnectionCleanup(
        cleanupID: UUID,
        active: ActiveConnection,
        failure: DiagnosticFailureKind,
        purpose: CmxTransportSessionPurpose,
        publishesAttributedFailure: Bool
    ) async {
        let attributedFailure = await recordSessionClosure(
            active: active,
            failure: failure,
            prefersAttributedFailure: publishesAttributedFailure
        )
        if publishesAttributedFailure,
           activeConnection == nil,
           pendingConnection == nil,
           controlOwner == nil {
            self.failure = attributedFailure
            publishSnapshot()
        }
        recordSessionLifecycle(
            .postCloseCleanupCompleted,
            sessionID: active.diagnosticID,
            purpose: purpose
        )
        retiredConnectionCleanups[cleanupID] = nil
    }

    private func reserveControlOwner(
        ownerID: UUID,
        purpose: CmxTransportSessionPurpose
    ) async throws {
        if let controlOwner {
            if controlOwner.id == ownerID { return }
        } else {
            controlOwner = ControlOwner(id: ownerID, purpose: purpose)
            publishSnapshot()
            return
        }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                if let controlOwner {
                    if controlOwner.id == ownerID {
                        continuation.resume()
                    } else {
                        controlWaiters.append(ControlWaiter(
                            id: waiterID,
                            ownerID: ownerID,
                            purpose: purpose,
                            continuation: continuation
                        ))
                    }
                } else {
                    controlOwner = ControlOwner(id: ownerID, purpose: purpose)
                    publishSnapshot()
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelControlWaiter(id: waiterID) }
        }

        do {
            try Task.checkCancellation()
            guard controlOwner?.id == ownerID else {
                throw CmxConnectivityEngineError.inactive
            }
        } catch {
            cancelControlWaiter(id: waiterID)
            if controlOwner?.id == ownerID {
                releaseControlOwner(ownerID: ownerID)
            }
            throw error
        }
    }

    private func cancelControlWaiter(id: UUID) {
        guard let index = controlWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        controlWaiters.remove(at: index).continuation.resume()
    }

    private func releaseControlOwner(ownerID: UUID) {
        guard controlOwner?.id == ownerID else { return }
        controlOwner = nil
        guard !controlWaiters.isEmpty else {
            publishSnapshot()
            return
        }
        let next = controlWaiters.removeFirst()
        controlOwner = ControlOwner(id: next.ownerID, purpose: next.purpose)
        publishSnapshot()
        next.continuation.resume()
    }

    private func cancelControlOwnership() {
        controlOwner = nil
        let waiters = controlWaiters
        controlWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func requirePeer(_ request: CmxByteTransportRequest) throws {
        guard try CmxConnectivityPeerID(request: request) == peerID else {
            throw CmxConnectivityEngineError.peerIntentMismatch
        }
    }

    private func pathDidChange(
        id: UUID,
        path: CmxIrohObservedConnectionPath
    ) async {
        guard let activeConnection, activeConnection.id == id else { return }
        // A normal remote close also ends with an unavailable path. Keep that
        // lifecycle on the closure observer so its attribution and control
        // ownership policy cannot be preempted by the path observer.
        guard !(await activeConnection.session.isClosed()),
              self.activeConnection?.id == id else { return }
        guard path != .unavailable else {
            await removeActiveConnection(
                matching: id,
                releasesControlOwner: true,
                reason: .allPathsClosed,
                failure: .noRoute
            )
            return
        }
        publishSnapshot()
    }

    private func makeDiagnosticSessionID() -> Int {
        if nextDiagnosticSessionID == Int.max {
            nextDiagnosticSessionID = 1
        } else {
            nextDiagnosticSessionID += 1
        }
        return nextDiagnosticSessionID
    }

    private func recordSessionLifecycle(
        _ kind: DiagnosticSessionLifecycleKind,
        sessionID: Int,
        purpose: CmxTransportSessionPurpose
    ) {
        diagnosticLog?.record(DiagnosticEvent(
            .transportSessionLifecycle,
            a: kind.rawValue,
            b: Int(purpose.rawValue),
            c: sessionID
        ))
    }

    private func recordSessionClosure(
        active: ActiveConnection,
        failure: DiagnosticFailureKind,
        prefersAttributedFailure: Bool
    ) async -> DiagnosticFailureKind {
        let attribution = await active.session.closeAttribution()
        if let diagnosticLog {
            let recorder = CmxIrohConnectionDiagnosticRecorder(
                diagnosticLog: diagnosticLog,
                sessionID: active.diagnosticID
            )
            recorder.record(attribution)
        }
        let recordedFailure = prefersAttributedFailure
            ? attribution.failureKind
            : failure
        diagnosticLog?.record(DiagnosticEvent(
            .sessionClosed,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: recordedFailure.rawValue,
            c: active.diagnosticID
        ))
        return recordedFailure
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
            controlLaneOwned: controlOwner != nil,
            controlPurpose: controlOwner?.purpose
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
