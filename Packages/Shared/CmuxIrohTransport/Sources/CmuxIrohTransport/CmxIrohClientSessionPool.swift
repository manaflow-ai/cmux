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
        let session: CmxIrohClientSession
        let closureTask: Task<Void, Never>
        let pathObservationTask: Task<Void, Never>
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let contextProvider: any CmxIrohClientContextProvider
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private var lifecycleRevision: UInt64 = 0
    private var runtimeGeneration: UInt64?
    private var sessions: [SessionKey: PooledSession] = [:]
    private var sessionOrder: [SessionKey] = []
    private var connectionTasks: [SessionKey: PendingConnection] = [:]
    private var controlOwners: [SessionKey: UUID] = [:]
    private var selectedPathContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1
    ) {
        self.supervisor = supervisor
        self.contextProvider = contextProvider
        self.protocolConfiguration = protocolConfiguration
    }

    func activate(runtimeGeneration: UInt64) async {
        guard self.runtimeGeneration != runtimeGeneration else { return }
        await invalidateAll()
        self.runtimeGeneration = runtimeGeneration
    }

    func deactivate() async {
        await invalidateAll()
        runtimeGeneration = nil
    }

    func session(for request: CmxByteTransportRequest) async throws -> CmxIrohClientSession {
        let key = try sessionKey(for: request)
        if let pooled = sessions[key] {
            return pooled.session
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
                session: connected,
                closureTask: closureTask,
                pathObservationTask: pathObservationTask
            )
            sessionOrder.removeAll { $0 == key }
            sessionOrder.append(key)
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
    /// pooled session. The owner remains reserved across a reentrant dial so a
    /// concurrent transport cannot install a second control reader.
    func acquireControlSession(
        for request: CmxByteTransportRequest,
        ownerID: UUID
    ) async throws -> CmxIrohClientSession {
        let key = try sessionKey(for: request)
        if let existing = controlOwners[key], existing != ownerID {
            throw CmxIrohByteTransportError.controlLaneAlreadyOwned
        }
        controlOwners[key] = ownerID
        do {
            return try await session(for: request)
        } catch {
            if controlOwners[key] == ownerID {
                controlOwners[key] = nil
            }
            throw error
        }
    }

    func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        let session = try await session(for: request)
        return try await session.openBidirectionalLane(lane, priority: priority)
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
        ownerID: UUID
    ) async {
        guard let key = try? sessionKey(for: request),
              controlOwners[key] == ownerID else {
            return
        }
        controlOwners[key] = nil
        await invalidateSession(for: key)
    }

    func invalidate(for request: CmxByteTransportRequest) async {
        guard let key = try? sessionKey(for: request) else { return }
        controlOwners[key] = nil
        await invalidateSession(for: key)
    }

    func invalidateAll() async {
        lifecycleRevision &+= 1
        let tasks = connectionTasks.values.map(\.task)
        connectionTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
        let closing = sessions.values
        sessions.removeAll(keepingCapacity: false)
        sessionOrder.removeAll(keepingCapacity: false)
        controlOwners.removeAll(keepingCapacity: false)
        for pooled in closing {
            pooled.closureTask.cancel()
            pooled.pathObservationTask.cancel()
            await pooled.session.close()
        }
        publishSelectedPathChange()
    }

    func selectedObservedPath() async -> CmxIrohObservedConnectionPath {
        guard let key = sessionOrder.last,
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

    private func sessionDidClose(key: SessionKey, sessionID: UUID) async {
        guard let pooled = sessions[key], pooled.id == sessionID else { return }
        sessions[key] = nil
        sessionOrder.removeAll { $0 == key }
        controlOwners[key] = nil
        pooled.pathObservationTask.cancel()
        await pooled.session.close()
        publishSelectedPathChange()
    }

    private func invalidateSession(for key: SessionKey) async {
        connectionTasks[key]?.task.cancel()
        connectionTasks[key] = nil
        let pooled = sessions.removeValue(forKey: key)
        sessionOrder.removeAll { $0 == key }
        pooled?.closureTask.cancel()
        pooled?.pathObservationTask.cancel()
        await pooled?.session.close()
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
              !deviceID.isEmpty,
              case let .peer(identity, _) = request.route.endpoint else {
            throw CmxIrohByteTransportError.missingPeerIntent
        }
        return SessionKey(
            runtimeGeneration: runtimeGeneration,
            identity: identity,
            deviceID: deviceID
        )
    }
}
