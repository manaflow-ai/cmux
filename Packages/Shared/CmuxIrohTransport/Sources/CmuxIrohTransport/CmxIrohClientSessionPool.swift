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

    private let supervisor: CmxIrohEndpointSupervisor
    private let contextProvider: any CmxIrohClientContextProvider
    private var lifecycleRevision: UInt64 = 0
    private var runtimeGeneration: UInt64?
    private var sessions: [SessionKey: CmxIrohClientSession] = [:]
    private var connectionTasks: [SessionKey: PendingConnection] = [:]

    init(
        supervisor: CmxIrohEndpointSupervisor,
        contextProvider: any CmxIrohClientContextProvider
    ) {
        self.supervisor = supervisor
        self.contextProvider = contextProvider
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
        if let session = sessions[key] {
            return session
        }

        let revision = lifecycleRevision
        let pending: PendingConnection
        if let existing = connectionTasks[key] {
            pending = existing
        } else {
            let supervisor = supervisor
            let contextProvider = contextProvider
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
                    }
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
                if installed !== connected {
                    await connected.close()
                }
                return installed
            }
            sessions[key] = connected
            return connected
        } catch {
            if connectionTasks[key]?.id == pending.id {
                connectionTasks[key] = nil
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

    func acceptInboundStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIrohInboundStream {
        let session = try await session(for: request)
        return try await session.acceptInboundStream()
    }

    func invalidate(for request: CmxByteTransportRequest) async {
        guard let key = try? sessionKey(for: request) else { return }
        connectionTasks[key]?.task.cancel()
        connectionTasks[key] = nil
        let session = sessions.removeValue(forKey: key)
        await session?.close()
    }

    func invalidateAll() async {
        lifecycleRevision &+= 1
        let tasks = connectionTasks.values.map(\.task)
        connectionTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
        let closing = sessions.values
        sessions.removeAll(keepingCapacity: false)
        for session in closing { await session.close() }
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
