import CMUXMobileCore
public import Foundation

/// Generation-scoped accept loop with bounded, timed admission work.
public actor CmxIrohEndpointServer {
    private static let initialAcceptRetryDelay: TimeInterval = 0.1
    private static let maximumAcceptRetryDelay: TimeInterval = 5

    public typealias ConnectionHandler = @Sendable (
        _ connection: any CmxIrohConnection,
        _ runtimeGeneration: UInt64,
        _ admission: AdmissionMarker
    ) async throws -> Void

    /// Generation-scoped application lifecycle for one accepted connection.
    ///
    /// Calling the value authenticates the connection. `markUsable()` promotes
    /// it only after the application protocol has proved ready end to end.
    public struct AdmissionMarker: Sendable {
        private let admit: @Sendable () async -> Bool
        private let promote: @Sendable () async -> Bool

        fileprivate init(
            admit: @escaping @Sendable () async -> Bool,
            promote: @escaping @Sendable () async -> Bool
        ) {
            self.admit = admit
            self.promote = promote
        }

        public func callAsFunction() async -> Bool {
            await admit()
        }

        public func markUsable() async -> Bool {
            await promote()
        }
    }
    typealias EndpointRecovery = @Sendable (
        _ expectedGeneration: UInt64
    ) async throws -> CmxIrohEndpointSnapshot

    private struct PendingAdmission {
        let generation: UInt64
        let remoteIdentity: CmxIrohPeerIdentity
        let connection: any CmxIrohConnection
        let handlerTask: Task<Void, Never>
        let deadlineTask: Task<Void, Never>
    }

    private struct ActiveConnection {
        let generation: UInt64
        let remoteIdentity: CmxIrohPeerIdentity
        let connection: any CmxIrohConnection
        let handlerTask: Task<Void, Never>
        let sequence: UInt64
        var isUsable: Bool
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let maximumPendingAdmissions: Int
    private let maximumPendingAdmissionsPerIdentity: Int
    private let maximumConnections: Int
    private let maximumConnectionsPerIdentity: Int
    private let admissionTimeout: TimeInterval
    private let clock: any CmxIrohRelayClock
    private let recoverEndpoint: EndpointRecovery
    private let handler: ConnectionHandler
    private var eventTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    private var pendingAdmissions: [UUID: PendingAdmission] = [:]
    private var activeConnections: [UUID: ActiveConnection] = [:]
    private var nextConnectionSequence: UInt64 = 0
    private var currentGeneration: UInt64?

    public init(
        supervisor: CmxIrohEndpointSupervisor,
        maximumPendingAdmissions: Int = 10,
        maximumPendingAdmissionsPerIdentity: Int = 1,
        maximumConnections: Int = 10,
        maximumConnectionsPerIdentity: Int = 2,
        admissionTimeout: TimeInterval = 15,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        handler: @escaping ConnectionHandler
    ) {
        self.init(
            supervisor: supervisor,
            maximumPendingAdmissions: maximumPendingAdmissions,
            maximumPendingAdmissionsPerIdentity: maximumPendingAdmissionsPerIdentity,
            maximumConnections: maximumConnections,
            maximumConnectionsPerIdentity: maximumConnectionsPerIdentity,
            admissionTimeout: admissionTimeout,
            clock: clock,
            recoverEndpoint: { _ in
                try await supervisor.ensureHealthy()
            },
            handler: handler
        )
    }

    init(
        supervisor: CmxIrohEndpointSupervisor,
        maximumPendingAdmissions: Int = 10,
        maximumPendingAdmissionsPerIdentity: Int = 1,
        maximumConnections: Int = 10,
        maximumConnectionsPerIdentity: Int = 2,
        admissionTimeout: TimeInterval = 15,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        recoverEndpoint: @escaping EndpointRecovery,
        handler: @escaping ConnectionHandler
    ) {
        precondition(maximumPendingAdmissions > 0)
        precondition(maximumPendingAdmissionsPerIdentity > 0)
        precondition(maximumPendingAdmissionsPerIdentity <= maximumPendingAdmissions)
        precondition(maximumConnections > 0)
        precondition(maximumConnectionsPerIdentity > 0)
        precondition(maximumConnectionsPerIdentity <= maximumConnections)
        precondition(admissionTimeout > 0)
        self.supervisor = supervisor
        self.maximumPendingAdmissions = maximumPendingAdmissions
        self.maximumPendingAdmissionsPerIdentity = maximumPendingAdmissionsPerIdentity
        self.maximumConnections = maximumConnections
        self.maximumConnectionsPerIdentity = maximumConnectionsPerIdentity
        self.admissionTimeout = admissionTimeout
        self.clock = clock
        self.recoverEndpoint = recoverEndpoint
        self.handler = handler
    }

    /// Begins observing endpoint generations. Calling this more than once is a no-op.
    public func start() {
        guard eventTask == nil else { return }
        let supervisor = supervisor
        eventTask = Task { [weak self] in
            let events = await supervisor.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    /// Cancels accepts and pending admissions without deactivating the shared endpoint.
    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        acceptTask?.cancel()
        acceptTask = nil
        currentGeneration = nil
        let admissions = pendingAdmissions.values
        pendingAdmissions.removeAll()
        let connections = activeConnections.values
        activeConnections.removeAll()
        for admission in admissions {
            admission.handlerTask.cancel()
            admission.deadlineTask.cancel()
            await admission.connection.close(
                errorCode: 1,
                reason: "server_stopped"
            )
        }
        for connection in connections {
            connection.handlerTask.cancel()
            await connection.connection.close(
                errorCode: 1,
                reason: "server_stopped"
            )
        }
    }

    /// Whether `generation` is still the endpoint accepted by this server.
    public func isCurrent(runtimeGeneration generation: UInt64) -> Bool {
        currentGeneration == generation && acceptTask != nil
    }

    private func handle(_ event: CmxIrohEndpointSupervisorEvent) async {
        guard case let .snapshot(snapshot) = event else { return }
        guard snapshot.state == .active else {
            acceptTask?.cancel()
            acceptTask = nil
            currentGeneration = nil
            await cancelConnections(exceptGeneration: nil, reason: "endpoint_inactive")
            return
        }
        guard currentGeneration != snapshot.runtimeGeneration || acceptTask == nil else {
            return
        }
        acceptTask?.cancel()
        await cancelConnections(
            exceptGeneration: snapshot.runtimeGeneration,
            reason: "stale_generation"
        )
        guard let endpoint = try? await supervisor.activeEndpoint() else { return }
        currentGeneration = snapshot.runtimeGeneration
        let generation = snapshot.runtimeGeneration
        acceptTask = Task { [weak self] in
            await self?.acceptLoop(endpoint: endpoint, generation: generation)
        }
    }

    private func acceptLoop(
        endpoint: any CmxIrohEndpoint,
        generation: UInt64
    ) async {
        var consecutiveFailures = 0
        while !Task.isCancelled, currentGeneration == generation {
            do {
                guard let connection = try await endpoint.accept() else { return }
                consecutiveFailures = 0
                guard currentGeneration == generation else {
                    await connection.close(errorCode: 1, reason: "stale_generation")
                    return
                }
                await startAdmission(connection: connection, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard currentGeneration == generation else { return }
                do {
                    let snapshot = try await recoverEndpoint(generation)
                    guard snapshot.runtimeGeneration == generation else { return }
                    let retryDelay = min(
                        Self.initialAcceptRetryDelay
                            * pow(2, Double(consecutiveFailures)),
                        Self.maximumAcceptRetryDelay
                    )
                    consecutiveFailures = min(consecutiveFailures + 1, 20)
                    try await clock.sleep(
                        until: clock.now().addingTimeInterval(retryDelay)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func startAdmission(
        connection: any CmxIrohConnection,
        generation: UInt64
    ) async {
        let remoteIdentity = await connection.remoteIdentity()
        guard currentGeneration == generation, !Task.isCancelled else {
            await connection.close(errorCode: 1, reason: "stale_generation")
            return
        }
        guard pendingAdmissions.count < maximumPendingAdmissions else {
            await connection.close(errorCode: 1, reason: "admission_capacity")
            return
        }
        let pendingForIdentity = pendingAdmissions.values.lazy.filter {
            $0.remoteIdentity == remoteIdentity
        }.count
        guard pendingForIdentity < maximumPendingAdmissionsPerIdentity else {
            await connection.close(
                errorCode: 1,
                reason: "admission_identity_capacity"
            )
            return
        }
        let activeForIdentity = activeConnections.values.lazy.filter {
            $0.remoteIdentity == remoteIdentity
        }.count
        let hasReplaceableConnection = activeConnections.values.contains {
            $0.remoteIdentity == remoteIdentity && !$0.isUsable
        }
        let canReserveReplacement = pendingForIdentity == 0
            && maximumConnectionsPerIdentity > 1
            && activeForIdentity >= maximumConnectionsPerIdentity
            && hasReplaceableConnection
        guard pendingAdmissions.count + activeConnections.count < maximumConnections
                || canReserveReplacement else {
            await connection.close(errorCode: 1, reason: "connection_capacity")
            return
        }
        guard pendingForIdentity + activeForIdentity < maximumConnectionsPerIdentity
                || canReserveReplacement else {
            await connection.close(
                errorCode: 1,
                reason: "connection_identity_capacity"
            )
            return
        }
        let id = UUID()
        let handler = handler
        let handlerTask = Task { [weak self] in
            do {
                try await handler(
                    connection,
                    generation,
                    AdmissionMarker(
                        admit: { [weak self] in
                            await self?.markAdmitted(id, generation: generation) ?? false
                        },
                        promote: { [weak self] in
                            await self?.markUsable(id, generation: generation) ?? false
                        }
                    )
                )
                await self?.finishHandler(id, error: nil)
            } catch {
                await self?.finishHandler(id, error: error)
            }
        }
        let clock = clock
        let deadline = clock.now().addingTimeInterval(admissionTimeout)
        let deadlineTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                await self?.timeOutAdmission(id)
            } catch {}
        }
        pendingAdmissions[id] = PendingAdmission(
            generation: generation,
            remoteIdentity: remoteIdentity,
            connection: connection,
            handlerTask: handlerTask,
            deadlineTask: deadlineTask
        )
    }

    private func markAdmitted(_ id: UUID, generation: UInt64) async -> Bool {
        guard currentGeneration == generation,
              let admission = pendingAdmissions.removeValue(forKey: id),
              admission.generation == generation else {
            return false
        }
        admission.deadlineTask.cancel()

        // An authenticated replacement may use the one admission reservation
        // above the steady identity bound. Reclaim only the oldest connection
        // that never became application-usable. A known-good session is retired
        // exclusively by markUsable below.
        let activeForIdentity = activeConnections.filter { _, connection in
            connection.generation == generation
                && connection.remoteIdentity == admission.remoteIdentity
        }
        let requiresReplacement = activeConnections.count >= maximumConnections
            || activeForIdentity.count >= maximumConnectionsPerIdentity
        let replaced = requiresReplacement
            ? activeForIdentity
                .filter { !$0.value.isUsable }
                .min { $0.value.sequence < $1.value.sequence }
            : nil
        if requiresReplacement, replaced == nil {
            return false
        }
        if let replaced {
            activeConnections[replaced.key] = nil
        }
        nextConnectionSequence &+= 1
        activeConnections[id] = ActiveConnection(
            generation: generation,
            remoteIdentity: admission.remoteIdentity,
            connection: admission.connection,
            handlerTask: admission.handlerTask,
            sequence: nextConnectionSequence,
            isUsable: false
        )
        if let replaced {
            replaced.value.handlerTask.cancel()
            await replaced.value.connection.close(
                errorCode: 0,
                reason: "superseded_unready_connection"
            )
        }
        return true
    }

    private func markUsable(_ id: UUID, generation: UInt64) async -> Bool {
        guard currentGeneration == generation,
              var promoted = activeConnections[id],
              promoted.generation == generation else {
            return false
        }
        if promoted.isUsable { return true }

        let superseded = activeConnections.filter { otherID, connection in
            otherID != id
                && connection.generation == generation
                && connection.remoteIdentity == promoted.remoteIdentity
        }
        for supersededID in superseded.keys {
            activeConnections[supersededID] = nil
        }
        promoted.isUsable = true
        activeConnections[id] = promoted
        for connection in superseded.values {
            connection.handlerTask.cancel()
            await connection.connection.close(
                errorCode: 0,
                reason: "superseded_connection"
            )
        }
        return true
    }

    private func finishHandler(_ id: UUID, error: (any Error)?) async {
        if let admission = pendingAdmissions.removeValue(forKey: id) {
            admission.deadlineTask.cancel()
            await admission.connection.close(
                errorCode: 1,
                reason: error == nil ? "admission_incomplete" : "admission_failed"
            )
            return
        }
        guard let active = activeConnections.removeValue(forKey: id) else {
            return
        }
        if error != nil {
            await active.connection.close(
                errorCode: 1,
                reason: "connection_failed"
            )
        }
    }

    private func timeOutAdmission(_ id: UUID) async {
        guard let admission = pendingAdmissions.removeValue(forKey: id) else {
            return
        }
        admission.handlerTask.cancel()
        await admission.connection.close(
            errorCode: 1,
            reason: "admission_timeout"
        )
    }

    private func cancelConnections(
        exceptGeneration retainedGeneration: UInt64?,
        reason: String
    ) async {
        let stale = pendingAdmissions.filter { _, admission in
            admission.generation != retainedGeneration
        }
        for id in stale.keys { pendingAdmissions[id] = nil }
        for admission in stale.values {
            admission.handlerTask.cancel()
            admission.deadlineTask.cancel()
            await admission.connection.close(errorCode: 1, reason: reason)
        }
        let active = activeConnections.filter { _, connection in
            connection.generation != retainedGeneration
        }
        for id in active.keys { activeConnections[id] = nil }
        for connection in active.values {
            connection.handlerTask.cancel()
            await connection.connection.close(errorCode: 1, reason: reason)
        }
    }
}
