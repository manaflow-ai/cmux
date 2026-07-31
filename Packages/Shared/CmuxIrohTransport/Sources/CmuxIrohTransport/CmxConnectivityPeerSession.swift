import CMUXMobileCore
import Foundation

/// Sole owner of dialing, admission, lanes, closure, and redial for one peer.
actor CmxConnectivityPeerSession {
    typealias SessionBuilder = @Sendable (
        _ request: CmxByteTransportRequest,
        _ attempt: CmxIrohConnectionAttempt
    ) async throws -> any CmxConnectivitySession
    typealias SnapshotHandler = @Sendable (
        _ snapshot: CmxConnectivityPeerSnapshot
    ) async -> Void

    private struct PendingConnection {
        let id: UUID
        let diagnosticID: Int
        let task: Task<any CmxConnectivitySession, any Error>
    }

    private struct ActiveConnection {
        let id: UUID
        let diagnosticID: Int
        let initialPurpose: CmxTransportSessionPurpose
        let session: any CmxConnectivitySession
        let closureTask: Task<Void, Never>
        let pathObservationTask: Task<Void, Never>
        let pathEventObservationTask: Task<Void, Never>?
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

    /// Bounds non-cooperative cancelled FFI work without serializing a healthy
    /// successor behind it. Once full, callers fail immediately until one
    /// retired attempt settles instead of creating an unbounded task chain.
    static var maximumRetiredDialCount: Int { 4 }

    let peerID: CmxConnectivityPeerID
    private let processIncarnation: UUID
    private let engineGeneration: UInt64
    private let buildSession: SessionBuilder
    private let handleSnapshot: SnapshotHandler
    private let diagnosticLog: DiagnosticLog?
    private var lifecycleRevision: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var stateRevision: UInt64 = 0
    private var nextDiagnosticSessionID = 0
    private var pendingConnection: PendingConnection?
    private var retiredDialDrains: [UUID: Task<Void, Never>] = [:]
    private var activeConnection: ActiveConnection?
    private var controlOwner: ControlOwner?
    private var controlWaiters: [ControlWaiter] = []
    private var controlRequiresRepair = false
    private var failure = DiagnosticFailureKind.none

    init(
        peerID: CmxConnectivityPeerID,
        processIncarnation: UUID = UUID(),
        engineGeneration: UInt64 = 1,
        buildSession: @escaping SessionBuilder,
        handleSnapshot: @escaping SnapshotHandler = { _ in },
        diagnosticLog: DiagnosticLog? = nil,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    ) {
        self.peerID = peerID
        precondition(engineGeneration > 0)
        self.processIncarnation = processIncarnation
        self.engineGeneration = engineGeneration
        self.buildSession = buildSession
        self.handleSnapshot = handleSnapshot
        self.diagnosticLog = diagnosticLog
        _ = clock
    }

    init(
        peerID: CmxConnectivityPeerID,
        processIncarnation: UUID = UUID(),
        engineGeneration: UInt64 = 1,
        buildSession: @escaping @Sendable (
            _ request: CmxByteTransportRequest
        ) async throws -> any CmxConnectivitySession,
        handleSnapshot: @escaping SnapshotHandler = { _ in },
        diagnosticLog: DiagnosticLog? = nil,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    ) {
        self.init(
            peerID: peerID,
            processIncarnation: processIncarnation,
            engineGeneration: engineGeneration,
            buildSession: { request, _ in
                try await buildSession(request)
            },
            handleSnapshot: handleSnapshot,
            diagnosticLog: diagnosticLog,
            clock: clock
        )
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
            let session = try await connectedSession(
                for: request,
                preservesControlOwnerOnClosed: true
            )
            guard controlRequiresRepair else { return session }
            do {
                try await session.repairControl()
                controlRequiresRepair = false
                failure = .none
                publishSnapshot()
                return session
            } catch {
                // A replacement stream can fail because the connection died or
                // because an older peer does not implement replacement lanes.
                // Only that concrete failure falls back to a full redial.
                await removeActiveConnection(
                    matching: activeConnection?.id,
                    releasesControlOwner: false,
                    reason: .controlReadFailed,
                    failure: DiagnosticFailureKind.classify(error)
                )
                controlRequiresRepair = false
                return try await connectedSession(
                    for: request,
                    preservesControlOwnerOnClosed: true
                )
            }
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
        if reason == .controlReadFailed || reason == .controlWriteFailed {
            controlRequiresRepair = true
            self.failure = failure
        }
        releaseControlOwner(ownerID: ownerID)
        publishSnapshot()
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
                if !(await activeConnection.session.isClosed()) {
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
                guard retiredDialDrains.count < Self.maximumRetiredDialCount else {
                    throw CmxConnectivityEngineError.superseded
                }
                connectionGeneration &+= 1
                failure = .none
                let buildSession = buildSession
                let attempt = CmxIrohConnectionAttempt(
                    processIncarnation: processIncarnation,
                    engineGeneration: engineGeneration,
                    dialGeneration: connectionGeneration,
                    diagnosticCorrelationID: request.diagnosticCorrelationID
                )
                let task = Task {
                    try Task.checkCancellation()
                    let session = try await buildSession(request, attempt)
                    guard !Task.isCancelled else {
                        await session.close()
                        throw CancellationError()
                    }
                    return session
                }
                pending = PendingConnection(
                    id: UUID(),
                    diagnosticID: request.diagnosticCorrelationID
                        ?? makeDiagnosticSessionID(),
                    task: task
                )
                pendingConnection = pending
                publishSnapshot()
            }

            let connected: any CmxConnectivitySession
            do {
                connected = try await pending.task.value
                guard lifecycleRevision == revision else {
                    await connected.close()
                    throw CmxConnectivityEngineError.superseded
                }
                if pendingConnection?.id == pending.id {
                    pendingConnection = nil
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
                if installed.id != pending.id {
                    await connected.close()
                }
                return installed.session
            }
            if await connected.isClosed() {
                await connected.close()
                guard corpseRetriesRemaining > 0 else {
                    throw CmxIrohClientSessionError.alreadyClosed
                }
                corpseRetriesRemaining -= 1
                continue redial
            }

            install(
                connected,
                id: pending.id,
                diagnosticID: pending.diagnosticID,
                purpose: request.sessionPurpose
            )
            return connected
        }
    }

    func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        let session = try await connectedSession(for: request)
        let connectionID = activeConnection?.id
        do {
            return try await session.openBidirectionalLane(lane, priority: priority)
        } catch {
            try Task.checkCancellation()
            guard await session.isClosed() else { throw error }
            await removeActiveConnection(
                matching: connectionID,
                releasesControlOwner: true,
                reason: .applicationLaneFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            let replacement = try await connectedSession(for: request)
            return try await replacement.openBidirectionalLane(
                lane,
                priority: priority
            )
        }
    }

    func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let session = try await connectedSession(for: request)
        return try await session.serverEventByteStream()
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
        retirePendingConnection()
        cancelControlOwnership()
        controlRequiresRepair = false
        await closeActiveConnection(
            releasesControlOwner: false,
            reason: .runtimeReconfigured,
            failure: failure
        )
        self.failure = failure
        publishSnapshot()
    }

    private func install(
        _ connected: any CmxConnectivitySession,
        id: UUID,
        diagnosticID: Int,
        purpose: CmxTransportSessionPurpose
    ) {
        let closureTask = Task { [weak self] in
            await connected.waitUntilClosed()
            guard !Task.isCancelled else { return }
            let attribution = await connected.closeAttribution()
            await self?.connectionDidClose(
                id: id,
                failure: attribution.failureKind
            )
        }
        let pathObservationTask = Task { [weak self] in
            let changes = await connected.observedSelectedPathChanges()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.pathDidChange(id: id)
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
        activeConnection = ActiveConnection(
            id: id,
            diagnosticID: diagnosticID,
            initialPurpose: purpose,
            session: connected,
            closureTask: closureTask,
            pathObservationTask: pathObservationTask,
            pathEventObservationTask: pathEventObservationTask
        )
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
        activeConnection.closureTask.cancel()
        activeConnection.pathObservationTask.cancel()
        activeConnection.pathEventObservationTask?.cancel()
        await activeConnection.pathEventObservationTask?.value
        await recordSessionClosure(
            .remoteClosed,
            active: activeConnection,
            failure: failure
        )
        if let owner = controlOwner {
            releaseControlOwner(ownerID: owner.id)
        }
        controlRequiresRepair = false
        self.failure = failure
        publishSnapshot()
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
        activeConnection.closureTask.cancel()
        activeConnection.pathObservationTask.cancel()
        activeConnection.pathEventObservationTask?.cancel()
        await activeConnection.session.close()
        await activeConnection.pathEventObservationTask?.value
        await recordSessionClosure(
            reason,
            active: activeConnection,
            failure: failure
        )
        if releasesControlOwner, let owner = controlOwner {
            releaseControlOwner(ownerID: owner.id)
        }
        controlRequiresRepair = false
        self.failure = failure
        publishSnapshot()
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

    private func retirePendingConnection() {
        guard let pending = pendingConnection else { return }
        pendingConnection = nil
        pending.task.cancel()
        let drainID = UUID()
        retiredDialDrains[drainID] = Task { [weak self] in
            let orphan = try? await pending.task.value
            if let self {
                await self.settleRetiredDial(id: drainID, orphan: orphan)
            } else if let orphan {
                await orphan.close()
            }
        }
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

    private func pathDidChange(id: UUID) {
        guard activeConnection?.id == id else { return }
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
        _ kind: DiagnosticSessionLifecycleKind,
        active: ActiveConnection,
        failure: DiagnosticFailureKind
    ) async {
        if let diagnosticLog {
            let recorder = CmxIrohConnectionDiagnosticRecorder(
                diagnosticLog: diagnosticLog,
                sessionID: active.diagnosticID
            )
            recorder.record(await active.session.closeAttribution())
        }
        recordSessionLifecycle(
            kind,
            sessionID: active.diagnosticID,
            purpose: controlOwner?.purpose ?? active.initialPurpose
        )
        diagnosticLog?.record(DiagnosticEvent(
            .sessionClosed,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: failure.rawValue,
            c: active.diagnosticID
        ))
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
