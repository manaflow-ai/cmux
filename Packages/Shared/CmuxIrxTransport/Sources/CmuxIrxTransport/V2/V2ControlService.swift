import Foundation

/// Owns one v2 control socket, request map, and credential-renewal lifecycle.
///
/// Construct one instance per full identity. Consume complete ``events()`` snapshots
/// to install credentials and peer permissions. Socket status does not determine
/// IROH reachability, and stopping this service never deletes Stack authentication.
public actor V2ControlService {
    let configuration: V2ControlConfiguration
    let dependencies: V2ControlDependencies
    let store: any V2StateStoring
    let codec = V2WireSigningCodec()
    var descriptor: V2DeviceDescriptor
    var cache: V2CachedState
    var status: V2ControlSnapshot.Status = .stopped
    var failure: V2ControlFailure?
    var sequence: UInt64 = 0
    var observers: [UUID: AsyncStream<V2ControlSnapshot>.Continuation] = [:]
    var runID: UUID?
    var runTask: Task<Void, Never>?
    var socketID: UUID?
    var socket: (any V2ControlSocket)?
    var receiveTask: Task<Void, Never>?
    var renewalTask: Task<Void, Never>?
    var directoryTask: Task<V2Directory, any Error>?
    var directorySyncTask: Task<Void, Never>?
    var ticketTask: Task<V2Ticket, any Error>?
    var relayTask: Task<[V2RelayCredential], any Error>?
    var authTask: Task<String, any Error>?
    var pending: [String: Pending] = [:]
    var cooldowns: [String: Date] = [:]
    var retiredAttempts: [String: Int] = [:]
    var forceStackOnNextSetup = false
    var loaded = false
    var ticketTaskID: UUID?
    var relayTaskID: UUID?
    var directoryTaskID: UUID?
    var directorySyncTaskID: UUID?
    var authTaskID: UUID?
    var wantedDirectoryRevision: Int = 0

    struct Pending {
        let schemaID: String
        let runID: UUID
        let continuation: CheckedContinuation<Data, any Error>
        var deadline: Task<Void, Never>?
        var sender: Task<Void, Never>?
    }

    /// Creates the service without starting sockets, key generation, or enrollment.
    /// - Parameters:
    ///   - configuration: The explicit v2 origin and full device identity.
    ///   - dependencies: Network, existing auth, same-key signing, and clock effects.
    ///   - store: A v2-only persistence implementation.
    public init(configuration: V2ControlConfiguration, dependencies: V2ControlDependencies, store: any V2StateStoring) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.store = store
        descriptor = configuration.device
        cache = V2CachedState(identity: configuration.device.identity)
    }

    /// Subscribes to complete current snapshots, including an immediate initial value.
    /// - Returns: A stream retaining only the latest state when its consumer is busy.
    public func events() -> AsyncStream<V2ControlSnapshot> {
        let id = UUID()
        let pair = AsyncStream<V2ControlSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = pair.continuation
        pair.continuation.yield(snapshot())
        return pair.stream
    }

    /// Reads current values without conflating control connectivity with peer connectivity.
    /// - Returns: A complete snapshot in this service's identity scope.
    public func snapshot() -> V2ControlSnapshot {
        V2ControlSnapshot(status: status, cache: cache, failure: failure, sequence: sequence)
    }

    /// Begins one owned run and publishes cached state before starting backend setup.
    ///
    /// The caller can begin cached IROH work as soon as the cache snapshot arrives.
    /// Repeated calls while active do not create another socket or renewal task.
    public func start() {
        guard runID == nil else { return }
        let id = UUID()
        runID = id
        status = .connecting
        publish()
        runTask = Task { [weak self] in await self?.run(id) }
    }

    /// Invalidates callbacks before cancelling networking, without erasing durable identity or auth.
    public func stop() async {
        runID = nil
        socketID = nil
        let oldSocket = socket
        socket = nil
        runTask?.cancel()
        runTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        cancelMaintenance()
        finishAll(throwing: V2ControlFailure.stopped)
        status = .stopped
        publish()
        await oldSocket?.close()
    }

    /// Checks a retained backend socket using protocol ping and refreshes due data independently.
    ///
    /// This does not reset any IROH peer. When iOS has discarded the socket while
    /// suspended, the existing reconnect owner resumes it.
    public func foreground() async {
        guard let run = runID else { return }
        if let socket, let connection = socketID {
            do { try await socket.ping() }
            catch { await socketFailed(error, run: run, connection: connection) }
        }
        guard runID == run else { return }
        scheduleMaintenance(run: run)
    }

    /// Allows a deliberate retry of a retired schema while preserving unrelated cooldowns.
    /// - Parameter schemaID: The specific method the user chose to retry.
    public func explicitRetry(schemaID: String) async {
        cooldowns.removeValue(forKey: schemaID)
        retiredAttempts.removeValue(forKey: schemaID)
        if runID != nil, status == .backingOff {
            await stop()
            start()
        }
    }

    func publish() {
        sequence &+= 1
        let value = snapshot()
        for observer in observers.values { observer.yield(value) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func assertCurrent(_ run: UUID) throws {
        guard runID == run, !Task.isCancelled else { throw V2ControlFailure.stopped }
    }

    func persist(run: UUID) async throws {
        try assertCurrent(run)
        let state = cache
        do { try await store.save(state) }
        catch { throw V2ControlFailure.persistenceFailed }
        try assertCurrent(run)
        publish()
    }

    func cancelMaintenance() {
        ticketTaskID = nil
        relayTaskID = nil
        directoryTaskID = nil
        directorySyncTaskID = nil
        authTaskID = nil
        renewalTask?.cancel()
        renewalTask = nil
        directoryTask?.cancel()
        directoryTask = nil
        directorySyncTask?.cancel()
        directorySyncTask = nil
        ticketTask?.cancel()
        ticketTask = nil
        relayTask?.cancel()
        relayTask = nil
        authTask?.cancel()
        authTask = nil
    }

    func finishAll(throwing error: any Error) {
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.deadline?.cancel()
            request.sender?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    func finish(_ id: String, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline?.cancel()
        request.sender?.cancel()
        request.continuation.resume(with: result)
    }

    func exchange(data: Data?, requestID: String, schemaID: String, run: UUID) async throws -> Data {
        try assertCurrent(run)
        try checkCooldown(schemaID)
        guard let socket else { throw V2ControlFailure.unavailable }
        guard pending[requestID] == nil, pending.count < configuration.maximumPendingRequests else {
            throw V2ControlFailure.capacityExceeded
        }
        if let data, data.count > 16 * 1024 { throw V2ControlFailure.capacityExceeded }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var request = Pending(schemaID: schemaID, runID: run, continuation: continuation)
                request.deadline = Task { [weak self, dependencies, configuration] in
                    do { try await dependencies.sleep(configuration.requestTimeout) }
                    catch { return }
                    await self?.finish(requestID, result: .failure(V2ControlFailure.requestTimedOut))
                }
                if let data {
                    request.sender = Task { [weak self] in
                        do { try await socket.send(data) }
                        catch { await self?.finish(requestID, result: .failure(error)) }
                    }
                }
                pending[requestID] = request
            }
        } onCancel: {
            Task { await self.finish(requestID, result: .failure(V2ControlFailure.stopped)) }
        }
    }

    func perform<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ request: Request, requestID: String, schemaID: String, response: Response.Type,
        run: UUID, canRefreshAuth: Bool = true
    ) async throws -> Response {
        let data = try codec.encode(request)
        do {
            let reply = try await exchange(data: data, requestID: requestID, schemaID: schemaID, run: run)
            try assertCurrent(run)
            guard !cache.authorityRevoked else { throw V2ControlFailure.stopped }
            let result = try JSONDecoder().decode(Response.self, from: reply)
            cooldowns.removeValue(forKey: schemaID)
            retiredAttempts.removeValue(forKey: schemaID)
            return result
        } catch let error as V2ControlFailure {
            if case .server(let rejected) = error,
               [.unauthorized, .ticketExpired].contains(rejected.code), canRefreshAuth {
                _ = try await refreshAPITicket(forceAuthRefresh: true)
                try assertCurrent(run)
                return try await perform(request, requestID: requestID, schemaID: schemaID, response: response, run: run, canRefreshAuth: false)
            }
            throw error
        } catch is DecodingError {
            throw V2ControlFailure.invalidWireData
        }
    }

    func checkCooldown(_ schema: String) throws {
        let until = [cooldowns[schema], cooldowns[operation(schema)]].compactMap { $0 }.max()
        if let until, until > dependencies.now() { throw V2ControlFailure.cooldown(schemaID: schema, until: until) }
    }

    func operation(_ schema: String) -> String { schema.split(separator: ".").dropLast().joined(separator: ".") }

    func record(_ error: V2ControlFailure, schema: String) {
        failure = error
        if case .server(let response) = error {
            if response.code == .rateLimited {
                cooldowns[operation(schema)] = dependencies.now().addingTimeInterval(max(1, Double(response.retryAfterMS ?? 60_000) / 1000))
            } else if response.code == .clientUpgradeRequired {
                let attempt = retiredAttempts[schema, default: 0]
                let delays: [TimeInterval] = [3600, 6 * 3600, 24 * 3600]
                let delay = delays[min(attempt, delays.count - 1)] * (1 + 0.1 * dependencies.jitter())
                retiredAttempts[schema] = attempt + 1
                cooldowns[schema] = dependencies.now().addingTimeInterval(delay)
            }
        }
        publish()
    }
}
