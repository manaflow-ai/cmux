import CMUXMobileCore
import Foundation

/// Retains one admitted multistream session per exact Mac peer intent.
actor CmxIrohClientSessionPool {
    private struct SessionKey: Hashable, Sendable {
        let runtimeGeneration: UInt64
        let identity: CmxIrohPeerIdentity
        let deviceID: String
    }

    private struct PendingConnection: Sendable {
        let id: UUID
        let task: Task<CmxIrohClientSession, any Error>
    }

    private struct PooledSession: Sendable {
        let id: UUID
        let diagnosticID: Int
        let initialPurpose: CmxTransportSessionPurpose
        let session: CmxIrohClientSession
        let closureTask: Task<Void, Never>
        let pathObservationTask: Task<Void, Never>
    }

    private struct ControlWaiter {
        let id: UUID
        let ownerID: UUID
        let purpose: CmxTransportSessionPurpose
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct ControlOwner {
        let id: UUID
        let purpose: CmxTransportSessionPurpose
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let contextProvider: any CmxIrohClientContextProvider
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let diagnosticLog: DiagnosticLog?
    private var lifecycleRevision: UInt64 = 0
    private var nextDiagnosticSessionID = 0
    private var runtimeGeneration: UInt64?
    private var sessions: [SessionKey: PooledSession] = [:]
    private var sessionOrder: [SessionKey] = []
    private var connectionTasks: [SessionKey: PendingConnection] = [:]
    private var controlOwners: [SessionKey: ControlOwner] = [:]
    private var controlWaiters: [SessionKey: [ControlWaiter]] = [:]
    private var selectedPathContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.supervisor = supervisor
        self.contextProvider = contextProvider
        self.protocolConfiguration = protocolConfiguration
        self.diagnosticLog = diagnosticLog
    }

    func activate(runtimeGeneration: UInt64) async {
        guard self.runtimeGeneration != runtimeGeneration else { return }
        await invalidateAll(reason: .runtimeReconfigured)
        self.runtimeGeneration = runtimeGeneration
    }

    func deactivate() async {
        await invalidateAll(reason: .runtimeDeactivated)
        runtimeGeneration = nil
    }

    func session(
        for request: CmxByteTransportRequest,
        preservesControlOwnerOnClosed: Bool = false
    ) async throws -> CmxIrohClientSession {
        let key = try sessionKey(for: request)
        while let pooled = sessions[key] {
            let isClosed = await pooled.session.isClosed()
            guard sessions[key]?.id == pooled.id else { continue }
            if !isClosed {
                return pooled.session
            }
            await invalidateSession(
                for: key,
                matching: pooled.id,
                releasesControlOwner: !preservesControlOwnerOnClosed,
                reason: .closedSessionEvicted,
                failure: .connectionClosed
            )
        }

        let revision = lifecycleRevision
        let pending: PendingConnection
        if let existing = connectionTasks[key] {
            pending = existing
        } else {
            let supervisor = supervisor
            let contextProvider = contextProvider
            let protocolConfiguration = protocolConfiguration
            let task = Task {
                let endpoint = try await supervisor.activeEndpoint()
                let context = try await contextProvider.context(for: request)
                let session = try CmxIrohClientSession(
                    endpoint: endpoint,
                    targetIdentity: key.identity,
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
                    try Task.checkCancellation()
                    return session
                } catch {
                    await session.close()
                    throw error
                }
            }
            pending = PendingConnection(id: UUID(), task: task)
            connectionTasks[key] = pending
        }

        do {
            let connected = try await pending.task.value
            guard lifecycleRevision == revision else {
                await connected.close()
                throw CancellationError()
            }
            if connectionTasks[key]?.id == pending.id {
                connectionTasks[key] = nil
            }
            if let installed = sessions[key] {
                if installed.session !== connected {
                    await connected.close()
                }
                return installed.session
            }
            let sessionID = UUID()
            let diagnosticID = makeDiagnosticSessionID()
            let closureTask = Task { [weak self] in
                await connected.waitUntilClosed()
                guard !Task.isCancelled else { return }
                await self?.sessionDidClose(key: key, sessionID: sessionID)
            }
            let pathObservationTask = Task { [weak self] in
                let changes = await connected.observedSelectedPathChanges()
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await self?.publishSelectedPathChange(
                        key: key,
                        sessionID: sessionID
                    )
                }
            }
            sessions[key] = PooledSession(
                id: sessionID,
                diagnosticID: diagnosticID,
                initialPurpose: request.sessionPurpose,
                session: connected,
                closureTask: closureTask,
                pathObservationTask: pathObservationTask
            )
            sessionOrder.removeAll { $0 == key }
            sessionOrder.append(key)
            recordSessionLifecycle(
                .established,
                sessionID: diagnosticID,
                purpose: controlOwners[key]?.purpose ?? request.sessionPurpose
            )
            publishSelectedPathChange()
            return connected
        } catch {
            if connectionTasks[key]?.id == pending.id {
                connectionTasks[key] = nil
            }
            throw error
        }
    }

    /// Acquires exact ownership of control-stream framing before returning the
    /// pooled session. Same-peer route variants wait for the existing owner to
    /// close instead of failing while an intentional reconnect is handing off.
    func acquireControlSession(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async throws -> CmxIrohClientSession {
        let key = try sessionKey(for: request)
        try await reserveControlOwner(
            for: key,
            ownerID: ownerID,
            purpose: request.sessionPurpose
        )
        do {
            return try await session(
                for: request,
                preservesControlOwnerOnClosed: true
            )
        } catch {
            if controlOwners[key]?.id == ownerID {
                releaseControlOwner(for: key, ownerID: ownerID)
            }
            throw error
        }
    }

    func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        let key = try sessionKey(for: request)
        let session = try await session(for: request)
        do {
            return try await session.openBidirectionalLane(lane, priority: priority)
        } catch {
            try Task.checkCancellation()
            guard await session.isClosed() else { throw error }
            await invalidateSession(
                for: key,
                matching: session,
                reason: .applicationLaneFailed,
                failure: DiagnosticFailureKind.classify(error)
            )
            let replacement = try await self.session(for: request)
            return try await replacement.openBidirectionalLane(
                lane,
                priority: priority
            )
        }
    }

    func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let session = try await session(for: request)
        return try await session.serverEventByteStream()
    }

    /// Releases an exact control owner and closes its session so partial RPC
    /// framing can never be inherited by a replacement owner.
    func releaseControlSession(
        for request: CmxByteTransportRequest,
        ownerID: UUID,
        reason: DiagnosticSessionLifecycleKind = .controlOwnerReleased,
        failure: DiagnosticFailureKind = .none
    ) async {
        guard let key = try? sessionKey(for: request),
              controlOwners[key]?.id == ownerID else {
            return
        }
        await invalidateSession(
            for: key,
            releasesControlOwner: false,
            reason: reason,
            failure: failure
        )
        releaseControlOwner(for: key, ownerID: ownerID)
    }

    func invalidate(for request: CmxByteTransportRequest) async {
        guard let key = try? sessionKey(for: request) else { return }
        await invalidateSession(
            for: key,
            reason: .explicitlyInvalidated,
            failure: .none
        )
    }

    func invalidateAll() async {
        await invalidateAll(reason: .runtimeDeactivated)
    }

    private func invalidateAll(reason: DiagnosticSessionLifecycleKind) async {
        lifecycleRevision &+= 1
        let tasks = connectionTasks.values.map(\.task)
        connectionTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
        let closing = sessions
        let closingOwners = controlOwners
        sessions.removeAll(keepingCapacity: false)
        sessionOrder.removeAll(keepingCapacity: false)
        controlOwners.removeAll(keepingCapacity: false)
        let waiters = controlWaiters.values.flatMap { $0 }
        controlWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.continuation.resume() }
        for (key, pooled) in closing {
            pooled.closureTask.cancel()
            pooled.pathObservationTask.cancel()
            recordSessionClosure(
                reason,
                pooled: pooled,
                purpose: closingOwners[key]?.purpose ?? pooled.initialPurpose,
                failure: .none
            )
            await pooled.session.close()
        }
        publishSelectedPathChange()
    }

    func selectedObservedPath() async -> CmxIrohObservedConnectionPath {
        let foregroundKey = sessionOrder.last { key in
            controlOwners[key]?.purpose == .foregroundControl
                && sessions[key] != nil
        }
        let controlKey = sessionOrder.last { key in
            controlOwners[key] != nil && sessions[key] != nil
        }
        guard let key = foregroundKey ?? controlKey ?? sessionOrder.last,
              let session = sessions[key]?.session else { return .unavailable }
        return await session.observedSelectedPath()
    }

    func selectedPathChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            selectedPathContinuations[id] = continuation
            continuation.yield(())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSelectedPathContinuation(id: id) }
            }
        }
    }

    func controlWaiterCount(for request: CmxByteTransportRequest) -> Int {
        guard let key = try? sessionKey(for: request) else { return 0 }
        return controlWaiters[key]?.count ?? 0
    }

    private func sessionDidClose(key: SessionKey, sessionID: UUID) async {
        guard let pooled = sessions[key], pooled.id == sessionID else { return }
        let owner = controlOwners[key]
        sessions[key] = nil
        sessionOrder.removeAll { $0 == key }
        pooled.pathObservationTask.cancel()
        recordSessionClosure(
            .remoteClosed,
            pooled: pooled,
            purpose: owner?.purpose ?? pooled.initialPurpose,
            failure: .connectionClosed
        )
        await pooled.session.close()
        if let owner {
            releaseControlOwner(for: key, ownerID: owner.id)
        }
        publishSelectedPathChange()
    }

    private func invalidateSession(
        for key: SessionKey,
        releasesControlOwner: Bool = true,
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        await invalidateSession(
            for: key,
            matching: Optional<UUID>.none,
            releasesControlOwner: releasesControlOwner,
            reason: reason,
            failure: failure
        )
    }

    private func invalidateSession(
        for key: SessionKey,
        matching expectedID: UUID?,
        releasesControlOwner: Bool = true,
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        if let expectedID, sessions[key]?.id != expectedID { return }
        let currentOwner = controlOwners[key]
        let owner = releasesControlOwner ? currentOwner : nil
        connectionTasks[key]?.task.cancel()
        connectionTasks[key] = nil
        let pooled = sessions.removeValue(forKey: key)
        sessionOrder.removeAll { $0 == key }
        pooled?.closureTask.cancel()
        pooled?.pathObservationTask.cancel()
        if let pooled {
            recordSessionClosure(
                reason,
                pooled: pooled,
                purpose: currentOwner?.purpose ?? pooled.initialPurpose,
                failure: failure
            )
        }
        await pooled?.session.close()
        if let owner {
            releaseControlOwner(for: key, ownerID: owner.id)
        }
        publishSelectedPathChange()
    }

    private func invalidateSession(
        for key: SessionKey,
        matching expectedSession: CmxIrohClientSession,
        reason: DiagnosticSessionLifecycleKind,
        failure: DiagnosticFailureKind
    ) async {
        guard let pooled = sessions[key], pooled.session === expectedSession else { return }
        await invalidateSession(
            for: key,
            matching: pooled.id,
            reason: reason,
            failure: failure
        )
    }

    private func reserveControlOwner(
        for key: SessionKey,
        ownerID: UUID,
        purpose: CmxTransportSessionPurpose
    ) async throws {
        if let existing = controlOwners[key] {
            if existing.id == ownerID { return }
        } else {
            controlOwners[key] = ControlOwner(id: ownerID, purpose: purpose)
            publishSelectedPathChangeIfEstablished(for: key)
            return
        }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                if let existing = controlOwners[key] {
                    if existing.id == ownerID {
                        continuation.resume()
                    } else {
                        controlWaiters[key, default: []].append(ControlWaiter(
                            id: waiterID,
                            ownerID: ownerID,
                            purpose: purpose,
                            continuation: continuation
                        ))
                    }
                } else {
                    controlOwners[key] = ControlOwner(id: ownerID, purpose: purpose)
                    publishSelectedPathChangeIfEstablished(for: key)
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelControlWaiter(for: key, id: waiterID) }
        }

        do {
            try Task.checkCancellation()
            guard controlOwners[key]?.id == ownerID else {
                throw CmxIrohClientRuntimeError.inactive
            }
        } catch {
            cancelControlWaiter(for: key, id: waiterID)
            if controlOwners[key]?.id == ownerID {
                releaseControlOwner(for: key, ownerID: ownerID)
            }
            throw error
        }
    }

    private func cancelControlWaiter(for key: SessionKey, id: UUID) {
        guard var waiters = controlWaiters[key],
              let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        controlWaiters[key] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume()
    }

    private func releaseControlOwner(for key: SessionKey, ownerID: UUID) {
        guard controlOwners[key]?.id == ownerID else { return }
        controlOwners[key] = nil
        guard var waiters = controlWaiters[key], !waiters.isEmpty else {
            publishSelectedPathChangeIfEstablished(for: key)
            return
        }
        let next = waiters.removeFirst()
        controlWaiters[key] = waiters.isEmpty ? nil : waiters
        controlOwners[key] = ControlOwner(id: next.ownerID, purpose: next.purpose)
        publishSelectedPathChangeIfEstablished(for: key)
        next.continuation.resume()
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
        pooled: PooledSession,
        purpose: CmxTransportSessionPurpose,
        failure: DiagnosticFailureKind
    ) {
        recordSessionLifecycle(
            kind,
            sessionID: pooled.diagnosticID,
            purpose: purpose
        )
        diagnosticLog?.record(DiagnosticEvent(
            .sessionClosed,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: failure.rawValue,
            c: pooled.diagnosticID
        ))
    }

    private func publishSelectedPathChangeIfEstablished(for key: SessionKey) {
        guard sessions[key] != nil else { return }
        publishSelectedPathChange()
    }

    private func publishSelectedPathChange() {
        for continuation in selectedPathContinuations.values {
            continuation.yield(())
        }
    }

    private func publishSelectedPathChange(key: SessionKey, sessionID: UUID) {
        guard sessions[key]?.id == sessionID else { return }
        publishSelectedPathChange()
    }

    private func removeSelectedPathContinuation(id: UUID) {
        selectedPathContinuations[id] = nil
    }

    private func sessionKey(for request: CmxByteTransportRequest) throws -> SessionKey {
        try request.route.validate()
        guard let runtimeGeneration else {
            throw CmxIrohClientRuntimeError.inactive
        }
        guard request.route.kind == .iroh,
              request.authorizationMode == .transportAdmission,
              let deviceID = request.expectedPeerDeviceID,
              let canonicalDeviceID = CmxIrohDeviceID(deviceID)?.value,
              case let .peer(identity, _) = request.route.endpoint else {
            throw CmxIrohByteTransportError.missingPeerIntent
        }
        return SessionKey(
            runtimeGeneration: runtimeGeneration,
            identity: identity,
            deviceID: canonicalDeviceID
        )
    }
}
