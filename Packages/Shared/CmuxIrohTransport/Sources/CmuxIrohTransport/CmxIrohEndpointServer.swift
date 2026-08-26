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
        let incoming: any CmxIrohIncomingConnection
        let handlerTask: Task<Void, Never>
        let deadlineTask: Task<Void, Never>
        /// Set once the server-side handshake completed and capacity checks
        /// passed. `nil` while the attempt is still establishing.
        var remoteIdentity: CmxIrohPeerIdentity?
        var connection: (any CmxIrohConnection)?
        /// Set when the admission deadline fired while the handshake was
        /// still in flight. The slot stays occupied until the attempt
        /// resolves; whichever of `registerEstablished`/`failEstablishment`
        /// observes the resolution releases it.
        var abandoned = false
    }

    /// The endpoint's accept queue ended while its generation is still
    /// current: the driver is gone but lifecycle state says active. Thrown
    /// into the recovery path so the supervisor re-verifies the endpoint
    /// instead of the accept loop dying silently.
    private struct AcceptQueueEndedError: Error {}

    private struct ActiveConnection {
        let generation: UInt64
        let remoteIdentity: CmxIrohPeerIdentity
        let connection: any CmxIrohConnection
        let handlerTask: Task<Void, Never>
        /// Awaits the transport's own terminal signal for this connection and
        /// releases the admission slot the moment it fires, so capacity is
        /// tied to connection liveness rather than to the handler unwinding.
        let closeWatcherTask: Task<Void, Never>
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
            if let connection = admission.connection {
                await connection.close(errorCode: 1, reason: "server_stopped")
            } else {
                await admission.incoming.abandon()
            }
        }
        for connection in connections {
            connection.handlerTask.cancel()
            connection.closeWatcherTask.cancel()
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
                guard let incoming = try await endpoint.accept() else {
                    // Never die silently: recovery below re-verifies the
                    // endpoint so a closed driver is replaced instead of
                    // leaving a published-but-undialable generation behind.
                    throw AcceptQueueEndedError()
                }
                consecutiveFailures = 0
                guard currentGeneration == generation else {
                    await incoming.abandon()
                    return
                }
                guard startAdmission(incoming: incoming, generation: generation) else {
                    // Admission is full. Abandoning here, on the loop, is
                    // deliberate backpressure: rejection work stays bounded to
                    // one attempt at a time instead of a remote flood minting
                    // unowned tasks.
                    await incoming.abandon()
                    continue
                }
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

    /// Starts one admission, or returns `false` when admission is at capacity
    /// and the caller must abandon the attempt itself.
    private func startAdmission(
        incoming: any CmxIrohIncomingConnection,
        generation: UInt64
    ) -> Bool {
        guard pendingAdmissions.count < maximumPendingAdmissions else {
            return false
        }
        let id = UUID()
        let handler = handler
        // The handshake runs inside this per-connection task, bounded by the
        // admission deadline below and by the driver's own handshake timeout,
        // so a peer that stops making progress costs only its own slot.
        let handlerTask = Task { [weak self] in
            let connection: any CmxIrohConnection
            do {
                connection = try await incoming.establish()
            } catch {
                await self?.failEstablishment(id)
                return
            }
            guard let self else {
                await connection.close(errorCode: 1, reason: "server_deallocated")
                return
            }
            guard await self.registerEstablished(id, connection: connection) else {
                return
            }
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
                await self.finishHandler(id, error: nil)
            } catch {
                await self.finishHandler(id, error: error)
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
            incoming: incoming,
            handlerTask: handlerTask,
            deadlineTask: deadlineTask
        )
        return true
    }

    /// Records a completed handshake against its pending admission and applies
    /// the identity-scoped capacity policy that used to run before the (then
    /// inline) handshake. Returns whether the connection may proceed to the
    /// application handler; a rejected or expired connection is closed here.
    private func registerEstablished(
        _ id: UUID,
        connection: any CmxIrohConnection
    ) async -> Bool {
        let remoteIdentity = await connection.remoteIdentity()
        if let admission = pendingAdmissions[id], admission.abandoned {
            // The admission deadline fired while this handshake was in
            // flight; its resolution releases the slot it kept occupied.
            pendingAdmissions[id] = nil
            await connection.close(errorCode: 1, reason: "admission_timeout")
            return false
        }
        guard var admission = pendingAdmissions[id],
              admission.generation == currentGeneration,
              admission.connection == nil else {
            // Timed out, superseded, or the server stopped while establishing.
            await connection.close(errorCode: 1, reason: "admission_expired")
            return false
        }
        let pendingForIdentity = pendingAdmissions.lazy.filter {
            $0.key != id && $0.value.remoteIdentity == remoteIdentity
        }.count
        guard pendingForIdentity < maximumPendingAdmissionsPerIdentity else {
            await rejectEstablished(
                id,
                connection: connection,
                reason: "admission_identity_capacity"
            )
            return false
        }
        let activeForIdentity = activeConnections.values.lazy.filter {
            $0.remoteIdentity == remoteIdentity
        }.count
        // A TLS-authenticated peer may always run one replacement admission
        // against its own connections: capacity held by a dead predecessor
        // must not refuse the redial until the idle timer notices the death.
        // The reservation is identity-scoped (a stranger has nothing of its
        // own to replace, so it can never preempt an occupied slot) and is
        // bounded to one in flight by the pending-per-identity check above.
        let canReserveReplacement = pendingForIdentity == 0
            && activeForIdentity > 0
        let otherPendingCount = pendingAdmissions.count - 1
        guard otherPendingCount + activeConnections.count < maximumConnections
                || canReserveReplacement else {
            await rejectEstablished(
                id,
                connection: connection,
                reason: "connection_capacity"
            )
            return false
        }
        guard pendingForIdentity + activeForIdentity < maximumConnectionsPerIdentity
                || canReserveReplacement else {
            await rejectEstablished(
                id,
                connection: connection,
                reason: "connection_identity_capacity"
            )
            return false
        }
        admission.remoteIdentity = remoteIdentity
        admission.connection = connection
        pendingAdmissions[id] = admission
        return true
    }

    private func rejectEstablished(
        _ id: UUID,
        connection: any CmxIrohConnection,
        reason: String
    ) async {
        if let admission = pendingAdmissions.removeValue(forKey: id) {
            admission.deadlineTask.cancel()
        }
        await connection.close(errorCode: 1, reason: reason)
    }

    private func failEstablishment(_ id: UUID) async {
        guard let admission = pendingAdmissions.removeValue(forKey: id) else {
            return
        }
        admission.deadlineTask.cancel()
        // An abandoned attempt was already refused at its deadline; removing
        // the entry above is what releases the slot its resolution freed.
        if !admission.abandoned {
            await admission.incoming.abandon()
        }
    }

    private func markAdmitted(_ id: UUID, generation: UInt64) async -> Bool {
        guard currentGeneration == generation,
              let admission = pendingAdmissions[id],
              admission.generation == generation,
              let remoteIdentity = admission.remoteIdentity,
              let connection = admission.connection else {
            return false
        }
        pendingAdmissions[id] = nil
        admission.deadlineTask.cancel()

        // An authenticated replacement may use the one admission reservation
        // above the steady identity bound. Reclaim the oldest connection that
        // never became application-usable; when only usable predecessors
        // exist (a dead peer's session stays "usable" until the idle timer
        // notices), admission proceeds one over the bound and markUsable
        // below retires the predecessor after the replacement proves itself,
        // so a live session is never torn down for an unproven redial and a
        // dead one stops pinning capacity. An identity with no connection of
        // its own can never exceed the bounds.
        let activeForIdentity = activeConnections.filter { _, connection in
            connection.generation == generation
                && connection.remoteIdentity == remoteIdentity
        }
        let requiresReplacement = activeConnections.count >= maximumConnections
            || activeForIdentity.count >= maximumConnectionsPerIdentity
        let replaced = requiresReplacement
            ? activeForIdentity
                .filter { !$0.value.isUsable }
                .min { $0.value.sequence < $1.value.sequence }
            : nil
        if requiresReplacement, replaced == nil, activeForIdentity.isEmpty {
            // Capacity filled between registerEstablished and this marker and
            // the identity has nothing of its own to replace. The pending
            // entry is already removed, so the server still owns the
            // established connection here and must close it before disowning
            // the admission; returning without closing would leave a live
            // QUIC connection outside every capacity table.
            await connection.close(errorCode: 1, reason: "connection_capacity")
            return false
        }
        if let replaced {
            activeConnections[replaced.key] = nil
        }
        nextConnectionSequence &+= 1
        let closeWatcherTask = Task { [weak self] in
            await connection.waitUntilClosed()
            await self?.releaseClosedConnection(id)
        }
        activeConnections[id] = ActiveConnection(
            generation: generation,
            remoteIdentity: remoteIdentity,
            connection: connection,
            handlerTask: admission.handlerTask,
            closeWatcherTask: closeWatcherTask,
            sequence: nextConnectionSequence,
            isUsable: false
        )
        if let replaced {
            replaced.value.handlerTask.cancel()
            replaced.value.closeWatcherTask.cancel()
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
            connection.closeWatcherTask.cancel()
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
            let reason = error == nil ? "admission_incomplete" : "admission_failed"
            if let connection = admission.connection {
                await connection.close(errorCode: 1, reason: reason)
            } else {
                await admission.incoming.abandon()
            }
            return
        }
        guard let active = activeConnections.removeValue(forKey: id) else {
            return
        }
        active.closeWatcherTask.cancel()
        if error != nil {
            await active.connection.close(
                errorCode: 1,
                reason: "connection_failed"
            )
        }
    }

    /// Releases the admission slot as soon as the transport reports the
    /// connection terminal (peer close, transport error, or its own timeout),
    /// instead of when the handler serving it eventually unwinds.
    private func releaseClosedConnection(_ id: UUID) {
        guard let active = activeConnections.removeValue(forKey: id) else {
            return
        }
        active.handlerTask.cancel()
        active.closeWatcherTask.cancel()
    }

    private func timeOutAdmission(_ id: UUID) async {
        guard var admission = pendingAdmissions[id] else { return }
        admission.handlerTask.cancel()
        if let connection = admission.connection {
            pendingAdmissions[id] = nil
            await connection.close(errorCode: 1, reason: "admission_timeout")
            return
        }
        // The handshake is still in flight, and cancellation does not reach
        // the native attempt: a consumed `Incoming` cannot be refused, and
        // the bindings do not propagate task cancellation into the driver.
        // Refuse the dialer fast, but keep the slot occupied until
        // establish() itself resolves (the driver's own handshake/idle
        // timeout bounds that), so a remote peer cannot mint more live
        // handshake work than `maximumPendingAdmissions` permits.
        admission.abandoned = true
        pendingAdmissions[id] = admission
        await admission.incoming.abandon()
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
            if let connection = admission.connection {
                await connection.close(errorCode: 1, reason: reason)
            } else {
                await admission.incoming.abandon()
            }
        }
        let active = activeConnections.filter { _, connection in
            connection.generation != retainedGeneration
        }
        for id in active.keys { activeConnections[id] = nil }
        for connection in active.values {
            connection.handlerTask.cancel()
            connection.closeWatcherTask.cancel()
            await connection.connection.close(errorCode: 1, reason: reason)
        }
    }
}
