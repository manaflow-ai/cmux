import CMUXMobileCore
import Foundation

/// Projects a connectivity-v2 peer's control lane through the mobile RPC byte seam.
actor CmxConnectivityByteTransport:
    CmxByteTransport,
    CmxByteTransportClosureObserving,
    CmxByteTransportClosureObservationReadiness,
    CmxByteTransportLivenessObserving,
    CmxByteTransportContinuityIdentifying,
    CmxByteTransportDiagnosticSessionIdentifying,
    CmxByteTransportPathObserving,
    CmxByteTransportSessionPurposeUpdating
{
    private var request: CmxByteTransportRequest
    private let engine: CmxConnectivityEngine
    private let ownerID = UUID()
    private var session: (any CmxConnectivitySession)?
    /// Changes whenever the admitted session is installed or torn down, so a
    /// path-observer registration cannot be attached to a session that closed
    /// while its stream was being requested.
    private var sessionGeneration = UUID()
    private var lastSession: (any CmxConnectivitySession)?
    private var ownsControlSession = false
    private var closed = false
    private var pathObservationTasks: [UUID: Task<Void, Never>] = [:]
    private var pathObservationContinuations:
        [UUID: AsyncStream<CmxTransportPath>.Continuation] = [:]
    private var closureObservationReadyWaiters: [CheckedContinuation<Void, Never>] = []

    init(request: CmxByteTransportRequest, engine: CmxConnectivityEngine) {
        self.request = request
        self.engine = engine
    }

    func connect() async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if session != nil { return }
        let connected = try await engine.acquireControl(
            for: request,
            ownerID: ownerID
        )
        guard !closed else {
            await engine.releaseControl(for: request, ownerID: ownerID)
            throw CmxIrohByteTransportError.alreadyClosed
        }
        ownsControlSession = true
        session = connected
        sessionGeneration = UUID()
        lastSession = connected
        resumeClosureObservationReadyWaiters()
    }

    func receive() async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        do {
            return try await session.receiveControl(maximumByteCount: 64 * 1_024)
        } catch {
            finishAllPathObservations()
            self.session = nil
            sessionGeneration = UUID()
            await releaseOwnedControlSession(
                reason: .controlReadFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let session else { throw CmxIrohByteTransportError.notConnected }
        do {
            try await session.sendControl(data)
        } catch {
            finishAllPathObservations()
            self.session = nil
            sessionGeneration = UUID()
            await releaseOwnedControlSession(
                reason: .controlWriteFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            throw error
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        finishAllPathObservations()
        resumeClosureObservationReadyWaiters()
        session = nil
        sessionGeneration = UUID()
        await releaseOwnedControlSession(
            reason: .controlOwnerReleased,
            failure: .none
        )
    }

    func transportContinuityID() async -> UInt64? {
        await session?.connectionContinuityID()
    }

    func transportDiagnosticSessionID() async -> Int? {
        await engine.diagnosticSessionID(for: request)
    }

    func transportClosureObservation() async -> CmxTransportClosureObservation? {
        guard let session else { return nil }
        guard let observationID = await session.makeClosureObservationID() else { return nil }
        return CmxTransportClosureObservation(waitUntilClosed: {
            await session.waitForClosure(observationID: observationID)
        }, cancel: {
            Task { await session.cancelClosureObservation(observationID: observationID) }
        })
    }

    func waitUntilTransportClosureObservationIsReady() async -> Bool {
        guard !closed else { return false }
        if let session {
            return !(await session.isClosed())
        }
        await withCheckedContinuation { continuation in
            if session != nil || closed {
                continuation.resume()
            } else {
                closureObservationReadyWaiters.append(continuation)
            }
        }
        guard !closed, let session else { return false }
        return !(await session.isClosed())
    }

    func isTransportClosed() async -> Bool {
        guard let session = session ?? lastSession else { return false }
        return await session.isClosed()
    }

    func currentTransportPath() async -> CmxTransportPath {
        guard let session else { return .unavailable }
        return await session.transportPath(
            for: await session.observedSelectedPath()
        )
    }

    func transportPathChanges() async -> AsyncStream<CmxTransportPath> {
        guard let session else {
            return unavailablePathStream()
        }
        let generation = sessionGeneration
        let changes = await session.observedSelectedPathChanges()
        // `observedSelectedPathChanges()` suspends the actor. A receive/send
        // failure or close may have retired this session while it was waiting;
        // never register a continuation against that stale stream.
        guard !closed, self.session != nil, sessionGeneration == generation else {
            return unavailablePathStream()
        }
        let observationID = UUID()
        let stream = AsyncStream<CmxTransportPath>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            pathObservationContinuations[observationID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.cancelPathObservation(observationID) }
            }
        }
        let task = Task { [weak self, session] in
            for await path in changes {
                guard !Task.isCancelled else { return }
                let projected = await session.transportPath(for: path)
                guard !Task.isCancelled else { return }
                await self?.yieldPathObservation(
                    observationID,
                    value: projected
                )
            }
            await self?.finishPathObservation(observationID)
        }
        pathObservationTasks[observationID] = task
        return stream
    }

    private func unavailablePathStream() -> AsyncStream<CmxTransportPath> {
        AsyncStream { continuation in
            continuation.yield(.unavailable)
            continuation.finish()
        }
    }

    private func cancelPathObservation(_ id: UUID) {
        pathObservationTasks.removeValue(forKey: id)?.cancel()
        pathObservationContinuations.removeValue(forKey: id)?.finish()
    }

    private func finishPathObservation(_ id: UUID) {
        pathObservationTasks[id] = nil
        pathObservationContinuations.removeValue(forKey: id)?.finish()
    }

    private func yieldPathObservation(
        _ id: UUID,
        value: CmxTransportPath
    ) {
        pathObservationContinuations[id]?.yield(value)
    }

    private func finishAllPathObservations() {
        for task in pathObservationTasks.values {
            task.cancel()
        }
        pathObservationTasks.removeAll()
        for continuation in pathObservationContinuations.values {
            continuation.finish()
        }
        pathObservationContinuations.removeAll()
    }

    func updateSessionPurpose(_ purpose: CmxTransportSessionPurpose) async {
        guard request.sessionPurpose != purpose else { return }
        request = request.withSessionPurpose(purpose)
        guard ownsControlSession else { return }
        await engine.updateControlPurpose(
            for: request,
            ownerID: ownerID,
            purpose: purpose
        )
    }

    private func releaseOwnedControlSession(
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        guard ownsControlSession else { return }
        ownsControlSession = false
        await engine.releaseControl(
            for: request,
            ownerID: ownerID,
            reason: reason,
            failure: failure
        )
    }

    private func resumeClosureObservationReadyWaiters() {
        let waiters = closureObservationReadyWaiters
        closureObservationReadyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
