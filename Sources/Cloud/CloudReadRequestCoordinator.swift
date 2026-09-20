import Foundation

/// Owns overlapping read requests for one VM client. Caller cancellation releases
/// only that waiter; the last waiter cancels the transport. A cancelled request
/// keeps its slot until teardown completes, preventing replacement amplification.
/// Caller deadlines are independent upper bounds. The shared transport also has
/// a fixed lifetime cap; reaching it fails even later callers without extending it.
actor CloudReadRequestCoordinator {
    @TaskLocal static var current: Context?

    private nonisolated let clock: CloudRequestClock
    private nonisolated let budget: Duration
    private let onNetworkChange: @Sendable (Bool) async -> Void
    private(set) var entries: [Key: Entry] = [:]
    private var networkTask: Task<Void, Never>?
    private var isOnline: Bool?
    private var cooldowns = CloudReadCooldownStore()

    init(clock: CloudRequestClock = CloudRequestClock(ContinuousClock()), budget: Duration = .seconds(30),
         onNetworkChange: @escaping @Sendable (Bool) async -> Void = { _ in }) {
        self.clock = clock
        self.budget = budget
        self.onNetworkChange = onNetworkChange
    }

    nonisolated func makeDeadline(elapsed: Duration = .zero, limit: Duration? = nil) -> Duration {
        clock.now() + min(budget, limit ?? budget) - elapsed
    }

    func read(_ key: Key, deadline: Duration? = nil, operation: @escaping @Sendable () async throws -> Response) async throws -> Response {
        let waiter = UUID()
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                join(key, waiter: waiter, deadline: deadline ?? makeDeadline(), continuation: continuation, operation: operation)
            }
        } onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        }
        try Task.checkCancellation()
        return response
    }

    private func join(
        _ key: Key, waiter: UUID, deadline: Duration, continuation: CheckedContinuation<Response, Error>,
        operation: @escaping @Sendable () async throws -> Response
    ) {
        cooldowns.activateSession(for: key)
        if clock.now() >= deadline {
            continuation.resume(throwing: URLError(.timedOut))
            return
        }
        if isOnline == false {
            continuation.resume(throwing: URLError(.notConnectedToInternet))
            return
        }
        if let entry = entries[key] {
            if entry.terminalError != nil {
                queueAfterTeardown(key, waiter: waiter, deadline: deadline, continuation: continuation, operation: operation)
            } else if clock.now() >= entry.transportDeadline {
                expire(key, id: entry.id)
                queueAfterTeardown(key, waiter: waiter, deadline: deadline, continuation: continuation, operation: operation)
            } else {
                entries[key]?.waiters[waiter] = Waiter(deadline: deadline, continuation: continuation)
                armTimer(key, id: entry.id)
            }
            return
        }
        if let response = cooldowns.response(for: key, now: seconds(clock.now())) {
            continuation.resume(returning: response)
            return
        }
        startEntry(key, id: UUID(),
                   waiters: [waiter: Waiter(deadline: deadline, continuation: continuation)], operation: operation)
    }

    private func startEntry(
        _ key: Key, id: UUID, waiters: [UUID: Waiter],
        operation: @escaping @Sendable () async throws -> Response
    ) {
        let waiters = unexpired(waiters)
        guard !waiters.isEmpty else { return }
        let transportDeadline = makeDeadline()
        if clock.now() >= transportDeadline || isOnline == false {
            let error = URLError(isOnline == false ? .notConnectedToInternet : .timedOut)
            for waiter in waiters.values { waiter.continuation.resume(throwing: error) }
            return
        }
        if let response = cooldowns.response(for: key, now: seconds(clock.now())) {
            for waiter in waiters.values { waiter.continuation.resume(returning: response) }
            return
        }
        entries[key] = Entry(id: id, transportDeadline: transportDeadline, waiters: waiters, operation: operation)
        startWork(key, id: id, operation: operation)
        armTimer(key, id: id)
    }

    private func armTimer(_ key: Key, id: UUID) {
        guard let entry = entries[key], entry.terminalError == nil else { return }
        entry.timer?.cancel()
        let deadline = min(entry.transportDeadline, entry.waiters.values.map(\.deadline).min() ?? entry.transportDeadline)
        entries[key]?.timer = Task { [weak self, clock] in
            do { try await clock.sleepUntil(deadline) } catch { return }
            await self?.expireDueWaiters(key, id: id)
        }
    }

    private func unexpired(_ waiters: [UUID: Waiter]) -> [UUID: Waiter] {
        let now = clock.now()
        return waiters.filter { _, waiter in
            guard waiter.deadline > now else {
                waiter.continuation.resume(throwing: URLError(.timedOut))
                return false
            }
            return true
        }
    }

    private func expireDueWaiters(_ key: Key, id: UUID) {
        guard let entry = entries[key], entry.id == id, entry.terminalError == nil else { return }
        if clock.now() >= entry.transportDeadline { expire(key, id: id); return }
        entries[key]?.waiters = unexpired(entry.waiters)
        if entries[key]?.waiters.isEmpty == true { expire(key, id: id) }
        else { armTimer(key, id: id) }
    }

    private func queueAfterTeardown(
        _ key: Key, waiter: UUID, deadline: Duration, continuation: CheckedContinuation<Response, Error>,
        operation: @escaping @Sendable () async throws -> Response
    ) {
        if let pending = entries[key]?.pending {
            entries[key]?.pending?.waiters[waiter] = Waiter(deadline: deadline, continuation: continuation)
            armPendingTimer(key, id: pending.id)
            return
        }
        let id = UUID()
        entries[key]?.pending = Pending(id: id, waiters: [waiter: Waiter(deadline: deadline, continuation: continuation)], operation: operation)
        armPendingTimer(key, id: id)
    }

    private func armPendingTimer(_ key: Key, id: UUID) {
        guard let pending = entries[key]?.pending, pending.id == id else { return }
        pending.timer?.cancel()
        let waiters = unexpired(pending.waiters)
        entries[key]?.pending?.waiters = waiters
        guard let deadline = waiters.values.map(\.deadline).min() else {
            entries[key]?.pending = nil
            return
        }
        entries[key]?.pending?.timer = Task { [weak self, clock] in
            do { try await clock.sleepUntil(deadline) } catch { return }
            await self?.armPendingTimer(key, id: id)
        }
    }

    private func expirePending(_ key: Key, id: UUID, error: URLError = URLError(.timedOut)) {
        guard let pending = entries[key]?.pending, pending.id == id else { return }
        entries[key]?.pending = nil
        pending.timer?.cancel()
        for waiter in pending.waiters.values { waiter.continuation.resume(throwing: error) }
    }

    private func startWork(_ key: Key, id: UUID, operation: @escaping @Sendable () async throws -> Response) {
        let context = Context(owner: self, key: key)
        entries[key]?.work = Task { [weak self] in
            let result: Result<Response, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await Self.$current.withValue(context, operation: operation))
            } catch {
                result = .failure(error)
            }
            await self?.finish(key, id: id, result: result)
        }
    }

    /// A completed mutation invalidates affected reads from the captured auth
    /// and team scope. Its readers share a trailing pass in the original budget.
    func invalidate(_ mutation: CloudReadMutation) {
        for path in mutation.affectedPaths {
            let key = Key(path: path, accountID: mutation.scope.accountID,
                          generation: mutation.scope.generation, teamID: mutation.scope.teamID)
            entries[key]?.invalidated = true
        }
    }

    /// Retains the server's minimum retry time across cancellation and later
    /// polls. Retry only while a live caller and the transport both have budget;
    /// otherwise return 429 now and preserve that minimum for future reads.
    func noteRetryAfter(_ key: Key, seconds: TimeInterval, response: Response) -> Bool {
        // Retry-After can contain Int.max seconds. Keep that distant deadline
        // as a monotonic floating-point instant rather than overflowing Duration.
        let until = self.seconds(clock.now()) + seconds
        cooldowns.record(key, until: until, now: self.seconds(clock.now()), response: response)
        guard let entry = entries[key], entry.terminalError == nil,
              let callerDeadline = entry.waiters.values.map(\.deadline).max() else { return false }
        return until < self.seconds(min(entry.transportDeadline, callerDeadline))
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func cancel(_ key: Key, waiter: UUID) {
        guard let removed = entries[key]?.waiters.removeValue(forKey: waiter) else {
            if let removed = entries[key]?.pending?.waiters.removeValue(forKey: waiter) {
                removed.continuation.resume(throwing: CancellationError())
                if entries[key]?.pending?.waiters.isEmpty == true {
                    entries[key]?.pending?.timer?.cancel()
                    entries[key]?.pending = nil
                }
            }
            return
        }
        removed.continuation.resume(throwing: CancellationError())
        if entries[key]?.waiters.isEmpty == true {
            entries[key]?.terminalError = URLError(.cancelled)
            entries[key]?.timer?.cancel()
            entries[key]?.work?.cancel()
        }
    }

    private func expire(_ key: Key, id: UUID, error: URLError = URLError(.timedOut)) {
        guard let entry = entries[key], entry.id == id, entry.terminalError == nil else { return }
        entries[key]?.terminalError = error
        entries[key]?.waiters.removeAll()
        entry.work?.cancel()
        entry.timer?.cancel()
        for waiter in entry.waiters.values { waiter.continuation.resume(throwing: error) }
    }

    private func finish(_ key: Key, id: UUID, result: Result<Response, Error>) {
        guard let entry = entries[key], entry.id == id else { return }
        // A response may run before the expired timer after sleep/wake. The
        // monotonic deadline decides the outcome, not executor delivery order.
        expireDueWaiters(key, id: id)
        if entry.invalidated, entries[key]?.terminalError == nil,
           case .success(let response) = result, (200...299).contains(response.http.statusCode) {
            entries[key]?.invalidated = false
            startWork(key, id: id, operation: entry.operation)
            return
        }
        guard let completed = entries.removeValue(forKey: key) else { return }
        completed.timer?.cancel()
        for waiter in completed.waiters.values { waiter.continuation.resume(with: result) }
        if let pending = completed.pending {
            pending.timer?.cancel()
            startEntry(key, id: pending.id, waiters: pending.waiters, operation: pending.operation)
        }
    }

    func observeNetwork(_ monitor: CloudReadNetworkMonitor) {
        networkTask?.cancel()
        networkTask = Task { [weak self, monitor] in
            for await online in monitor.updates {
                guard !Task.isCancelled else { return }
                await self?.networkChanged(isOnline: online)
            }
        }
    }

    func networkChanged(isOnline: Bool) async {
        let changed = self.isOnline != isOnline && (self.isOnline != nil || !isOnline)
        self.isOnline = isOnline
        if !isOnline {
            for (key, entry) in entries {
                expire(key, id: entry.id, error: URLError(.notConnectedToInternet))
                if let pending = entry.pending { expirePending(key, id: pending.id, error: URLError(.notConnectedToInternet)) }
            }
        }
        if changed { await onNetworkChange(isOnline) }
    }

    deinit {
        networkTask?.cancel()
        for entry in entries.values {
            entry.work?.cancel()
            entry.timer?.cancel()
            for waiter in entry.waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
            if let pending = entry.pending {
                pending.timer?.cancel()
                for waiter in pending.waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
            }
        }
    }
}
