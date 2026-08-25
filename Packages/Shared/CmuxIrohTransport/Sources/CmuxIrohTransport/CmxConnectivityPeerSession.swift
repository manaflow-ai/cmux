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

    /// A cancelled FFI dial normally settles immediately. This bound prevents
    /// one non-cooperative endpoint implementation from blocking every redial.
    static var retiredDialSettleWaitLimitSeconds: TimeInterval { 10 }
    private static let maximumRetiredDialCleanupCount = 8

    /// Bounded grace between an `.unavailable` selected-path observation and
    /// eviction. Iroh can briefly publish no selected path while moving between
    /// direct and relay paths. Immediate eviction tears down an admitted RPC
    /// session during that normal transition. A persistently pathless session
    /// still cannot outlive this deadline if its closure callback stalls.
    static var allPathsClosedEvictionGraceSeconds: TimeInterval { 15 }

    let peerID: CmxConnectivityPeerID
    private let peerAlias: UInt32?
    private let buildSession: SessionBuilder
    private let handleSnapshot: SnapshotHandler
    private let diagnosticLog: DiagnosticLog?
    private let clock: any CmxIrohRelayClock
    private var lifecycleRevision: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var stateRevision: UInt64 = 0
    private var nextDiagnosticSessionID = 0
    private var pendingConnection: PendingConnection?
    private var retiredDialDrains: [UUID: Task<Void, Never>] = [:]
    // Timed-out drains remain owned by a bounded cleanup set until their
    // wrapper observes the canceled dial. This prevents repeated wedges from
    // accumulating unowned tasks while allowing replacement dialing.
    private var retiredDialCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var retiredDialWaiters: [
        UUID: CheckedContinuation<Void, Never>
    ] = [:]
    private var retiredDialWaiterGenerations: [UUID: UInt64] = [:]
    private var retiredDialGeneration: UInt64 = 0
    // A test clock (and a very fast production clock) can expire the deadline
    // before the continuation below is registered. Keep that one-shot result
    // until the waiter observes it instead of dropping the wake-up.
    private var expiredRetiredDialWaiters: Set<UUID> = []
    private var activeConnection: ActiveConnection?
    private var allPathsClosedEviction: (
        connectionID: UUID,
        task: Task<Void, Never>
    )?
    private var controlOwner: ControlOwner?
    private var controlWaiters: [ControlWaiter] = []
    private var failure = DiagnosticFailureKind.none

    init(
        peerID: CmxConnectivityPeerID,
        buildSession: @escaping SessionBuilder,
        handleSnapshot: @escaping SnapshotHandler = { _ in },
        diagnosticLog: DiagnosticLog? = nil,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    ) {
        self.peerID = peerID
        self.peerAlias = DiagnosticCorrelation().handle(for: peerID.deviceID)
        self.buildSession = buildSession
        self.handleSnapshot = handleSnapshot
        self.diagnosticLog = diagnosticLog
        self.clock = clock
    }

    func snapshot() -> CmxConnectivityPeerSnapshot {
        makeSnapshot()
    }

    func acquireControl(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async throws -> any CmxConnectivitySession {
        try requirePeer(request)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await reserveControlOwner(
                    ownerID: ownerID,
                    purpose: request.sessionPurpose
                )
                try Task.checkCancellation()
                let session = try await connectedSession(
                    for: request,
                    preservesControlOwnerOnClosed: true
                )
                // The dial can finish while the caller's cancellation
                // handler is waiting to release the owner. Do not hand a
                // newly installed session back to that cancelled caller; the
                // catch path below will synchronously retire its ownership.
                try Task.checkCancellation()
                return session
            } onCancel: {
                // `pendingConnection` is an unstructured, peer-owned dial. A
                // cancelled RPC owner cannot rely on cancellation propagating
                // through `Task.value`, so explicitly release the control
                // reservation. The actor then retires the exact physical dial.
                Task { [weak self] in
                    await self?.releaseControl(
                        ownerID: ownerID,
                        reason: .controlOwnerReleased,
                        failure: .cancelled
                    )
                }
            }
        } catch {
            if controlOwner?.id == ownerID {
                await releaseControl(
                    ownerID: ownerID,
                    reason: .controlOwnerReleased,
                    failure: DiagnosticFailureKind.classify(error)
                )
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
        if pendingConnection != nil {
            // The control owner is the only authority allowed to publish this
            // pending connection. Invalidate its captured revision before
            // cancellation so even a completion racing this release is closed
            // instead of installed without an owner.
            lifecycleRevision &+= 1
            retirePendingConnection()
        }
        await closeActiveConnection(
            releasesControlOwner: false,
            reason: reason,
            failure: failure
        )
        releaseControlOwner(ownerID: ownerID)
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
                connectionGeneration &+= 1
                failure = .none
                let buildSession = buildSession
                let task = Task { [weak self] in
                    await self?.waitForRetiredDials()
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
                if installed.id == pending.id {
                    return installed.session
                }
                if let winner = await settleRedundantDial(
                    connected,
                    installedID: installed.id
                ) {
                    return winner
                }
                continue redial
            }
            if await connected.isClosed() {
                await connected.close()
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
                    return installed.session
                }
                if let winner = await settleRedundantDial(
                    connected,
                    installedID: installed.id
                ) {
                    return winner
                }
                continue redial
            }
            install(
                connected,
                id: pending.id,
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

    /// Returns the diagnostic session currently admitted for this peer.
    func diagnosticSessionID() -> Int? {
        activeConnection?.diagnosticID
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
        await closeActiveConnection(
            releasesControlOwner: false,
            reason: .runtimeReconfigured,
            failure: failure
        )
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
        purpose: CmxTransportSessionPurpose
    ) {
        let diagnosticID = makeDiagnosticSessionID()
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
            let attribution = await connected.closeAttribution()
            await self?.connectionDidClose(
                id: id,
                failure: attribution.failureKind
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
                sessionID: diagnosticID,
                peerAlias: peerAlias
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
        disarmAllPathsClosedEviction(for: activeConnection.id)
        let removedOwner = controlOwner
        let closurePurpose = removedOwner?.purpose
            ?? activeConnection.initialPurpose
        activeConnection.closureTask?.cancel()
        activeConnection.pathObservationTask?.cancel()
        activeConnection.pathEventObservationTask?.cancel()
        await activeConnection.pathEventObservationTask?.value
        await recordSessionClosure(
            .remoteClosed,
            active: activeConnection,
            failure: failure,
            purpose: closurePurpose
        )
        guard self.activeConnection == nil,
              pendingConnection == nil else { return }
        if let owner = removedOwner {
            releaseControlOwner(ownerID: owner.id)
        }
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
        disarmAllPathsClosedEviction(for: activeConnection.id)
        let removedOwner = controlOwner
        let closurePurpose = removedOwner?.purpose
            ?? activeConnection.initialPurpose
        activeConnection.closureTask?.cancel()
        activeConnection.pathObservationTask?.cancel()
        activeConnection.pathEventObservationTask?.cancel()
        await activeConnection.session.close()
        await activeConnection.pathEventObservationTask?.value
        await recordSessionClosure(
            reason,
            active: activeConnection,
            failure: failure,
            purpose: closurePurpose
        )
        guard self.activeConnection == nil,
              pendingConnection == nil else { return }
        if releasesControlOwner, let owner = removedOwner {
            releaseControlOwner(ownerID: owner.id)
        }
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
        // A timeout may still be queued for an older drain. Tie it to this
        // retirement generation so it cannot clear a replacement drain.
        retiredDialGeneration &+= 1
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
        retiredDialCleanupTasks[id] = nil
        guard retiredDialDrains.isEmpty else { return }
        let waiters = retiredDialWaiters.values
        for waiterID in retiredDialWaiters.keys {
            retiredDialWaiterGenerations.removeValue(forKey: waiterID)
            expiredRetiredDialWaiters.remove(waiterID)
        }
        retiredDialWaiters.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    private func waitForRetiredDials() async {
        guard !retiredDialDrains.isEmpty else { return }
        let waiterID = UUID()
        retiredDialWaiterGenerations[waiterID] = retiredDialGeneration
        let clock = clock
        let deadline = clock.now().addingTimeInterval(
            Self.retiredDialSettleWaitLimitSeconds
        )
        let timeout = Task { [weak self] in
            try? await clock.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            await self?.expireRetiredDialWait(id: waiterID)
        }
        defer {
            timeout.cancel()
            expiredRetiredDialWaiters.remove(waiterID)
            retiredDialWaiterGenerations.removeValue(forKey: waiterID)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    expiredRetiredDialWaiters.remove(waiterID)
                    retiredDialWaiterGenerations.removeValue(forKey: waiterID)
                    continuation.resume()
                } else if retiredDialDrains.isEmpty {
                    continuation.resume()
                } else if expiredRetiredDialWaiters.remove(waiterID) != nil {
                    continuation.resume()
                } else {
                    retiredDialWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resumeRetiredDialWaiter(id: waiterID)
            }
        }
    }

    private func resumeRetiredDialWaiter(id: UUID) {
        guard let continuation = retiredDialWaiters.removeValue(forKey: id) else {
            return
        }
        expiredRetiredDialWaiters.remove(id)
        retiredDialWaiterGenerations.removeValue(forKey: id)
        continuation.resume()
    }

    private func expireRetiredDialWait(id: UUID) {
        guard !Task.isCancelled,
              retiredDialWaiterGenerations[id] == retiredDialGeneration else {
            return
        }
        let timedOutDrains = retiredDialDrains
        retiredDialDrains.removeAll()
        for (drainID, drain) in timedOutDrains {
            drain.cancel()
            retiredDialCleanupTasks[drainID] = drain
        }
        while retiredDialCleanupTasks.count > Self.maximumRetiredDialCleanupCount {
            guard let oldestID = retiredDialCleanupTasks.keys.first else { break }
            retiredDialCleanupTasks[oldestID]?.cancel()
            retiredDialCleanupTasks.removeValue(forKey: oldestID)
        }
        let waiters = retiredDialWaiters.values
        let registeredWaiterIDs = Set(retiredDialWaiters.keys)
        for waiterID in retiredDialWaiterGenerations.keys where
            !registeredWaiterIDs.contains(waiterID) {
            expiredRetiredDialWaiters.insert(waiterID)
        }
        for waiterID in retiredDialWaiters.keys {
            retiredDialWaiterGenerations.removeValue(forKey: waiterID)
            expiredRetiredDialWaiters.remove(waiterID)
        }
        retiredDialWaiters.removeAll()
        if waiters.isEmpty {
            // Retain a timeout that won before its continuation registered.
            expiredRetiredDialWaiters.insert(id)
        } else {
            for continuation in waiters {
                continuation.resume()
            }
        }
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
            armAllPathsClosedEviction(for: id)
            return
        }
        disarmAllPathsClosedEviction(for: id)
        publishSnapshot()
    }

    private func armAllPathsClosedEviction(for id: UUID) {
        guard activeConnection?.id == id else { return }
        if allPathsClosedEviction?.connectionID == id { return }
        allPathsClosedEviction?.task.cancel()
        let clock = clock
        let deadline = clock.now().addingTimeInterval(
            Self.allPathsClosedEvictionGraceSeconds
        )
        let task = Task { [weak self] in
            try? await clock.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            await self?.evictIfPathsStillClosed(for: id)
        }
        allPathsClosedEviction = (connectionID: id, task: task)
    }

    private func disarmAllPathsClosedEviction(for id: UUID) {
        guard let armed = allPathsClosedEviction,
              armed.connectionID == id else { return }
        armed.task.cancel()
        allPathsClosedEviction = nil
    }

    private func evictIfPathsStillClosed(for id: UUID) async {
        if let armed = allPathsClosedEviction, armed.connectionID == id {
            allPathsClosedEviction = nil
        }
        guard let active = activeConnection, active.id == id else { return }
        // Re-read live state at the deadline so a dropped recovery event cannot
        // evict a healthy connection. The closure observer remains authoritative
        // when the QUIC connection itself has already terminated.
        guard !(await active.session.isClosed()),
              self.activeConnection?.id == id else { return }
        guard await active.session.observedSelectedPath() == .unavailable,
              self.activeConnection?.id == id else { return }
        await removeActiveConnection(
            matching: id,
            releasesControlOwner: true,
            reason: .allPathsClosed,
            failure: .noRoute
        )
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
            surface: peerAlias,
            a: kind.rawValue,
            b: Int(purpose.rawValue),
            c: sessionID
        ))
    }

    private func recordSessionClosure(
        _ kind: DiagnosticSessionLifecycleKind,
        active: ActiveConnection,
        failure: DiagnosticFailureKind,
        purpose: CmxTransportSessionPurpose
    ) async {
        if let diagnosticLog {
            let recorder = CmxIrohConnectionDiagnosticRecorder(
                diagnosticLog: diagnosticLog,
                sessionID: active.diagnosticID,
                peerAlias: peerAlias
            )
            recorder.record(await active.session.closeAttribution())
        }
        recordSessionLifecycle(
            kind,
            sessionID: active.diagnosticID,
            purpose: purpose
        )
        diagnosticLog?.record(DiagnosticEvent(
            .sessionClosed,
            surface: peerAlias,
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
