public import Foundation

/// Generation-scoped accept loop with bounded, timed admission work.
public actor CmxIrohEndpointServer {
    public typealias ConnectionHandler = @Sendable (
        _ connection: any CmxIrohConnection,
        _ runtimeGeneration: UInt64
    ) async throws -> Void

    private enum AdmissionError: Error {
        case timedOut
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let maximumPendingAdmissions: Int
    private let admissionTimeout: TimeInterval
    private let clock: any CmxIrohRelayClock
    private let handler: ConnectionHandler
    private var eventTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    private var pendingAdmissions: [UUID: Task<Void, Never>] = [:]
    private var currentGeneration: UInt64?

    public init(
        supervisor: CmxIrohEndpointSupervisor,
        maximumPendingAdmissions: Int = 10,
        admissionTimeout: TimeInterval = 15,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        handler: @escaping ConnectionHandler
    ) {
        precondition(maximumPendingAdmissions > 0)
        precondition(admissionTimeout > 0)
        self.supervisor = supervisor
        self.maximumPendingAdmissions = maximumPendingAdmissions
        self.admissionTimeout = admissionTimeout
        self.clock = clock
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
    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        acceptTask?.cancel()
        acceptTask = nil
        currentGeneration = nil
        let tasks = pendingAdmissions.values
        pendingAdmissions.removeAll()
        for task in tasks { task.cancel() }
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
            return
        }
        guard currentGeneration != snapshot.runtimeGeneration || acceptTask == nil else {
            return
        }
        acceptTask?.cancel()
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
        do {
            while !Task.isCancelled, currentGeneration == generation {
                guard let connection = try await endpoint.accept() else { return }
                guard currentGeneration == generation else {
                    await connection.close(errorCode: 1, reason: "stale_generation")
                    return
                }
                startAdmission(connection: connection, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard currentGeneration == generation else { return }
            acceptTask = nil
        }
    }

    private func startAdmission(
        connection: any CmxIrohConnection,
        generation: UInt64
    ) {
        guard pendingAdmissions.count < maximumPendingAdmissions else {
            Task {
                await connection.close(errorCode: 1, reason: "admission_capacity")
            }
            return
        }
        let id = UUID()
        let handler = handler
        let clock = clock
        let deadline = clock.now().addingTimeInterval(admissionTimeout)
        pendingAdmissions[id] = Task { [weak self] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await handler(connection, generation)
                    }
                    group.addTask {
                        try await clock.sleep(until: deadline)
                        try Task.checkCancellation()
                        throw AdmissionError.timedOut
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                await connection.close(errorCode: 1, reason: "admission_failed")
            }
            await self?.finishAdmission(id)
        }
    }

    private func finishAdmission(_ id: UUID) {
        pendingAdmissions[id] = nil
    }
}
