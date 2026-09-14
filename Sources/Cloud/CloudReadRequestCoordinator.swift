import Foundation

/// Owns overlapping read requests for one VM client. Caller cancellation releases
/// only that waiter; the last waiter cancels the transport. A cancelled request
/// keeps its slot until teardown completes, preventing replacement amplification.
actor CloudReadRequestCoordinator {
    struct Key: Hashable, Sendable {
        let path: String
        let accountID: String?
        let generation: UInt64?
        let teamID: String?
    }

    struct Response: Sendable {
        let data: Data
        let http: HTTPURLResponse
    }

    struct Context: Sendable {
        weak var owner: CloudReadRequestCoordinator?
        let key: Key
    }

    @TaskLocal static var current: Context?

    struct Entry: Sendable {
        let id: UUID
        var deadline: Duration
        var waiters: [UUID: CheckedContinuation<Response, Error>]
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var terminalError: URLError?
        var invalidated = false
        let operation: @Sendable () async throws -> Response
        var pending: Pending?
    }

    struct Pending: Sendable {
        let id: UUID
        var deadline: Duration
        var waiters: [UUID: CheckedContinuation<Response, Error>]
        let operation: @Sendable () async throws -> Response
        var timer: Task<Void, Never>?
    }

    private struct Cooldown {
        let until: TimeInterval
        let response: Response
    }

    private nonisolated let clock: CloudRequestClock
    private nonisolated let budget: Duration
    private let onNetworkChange: @Sendable (Bool) async -> Void
    private(set) var entries: [Key: Entry] = [:]
    private var networkTask: Task<Void, Never>?
    private var isOnline: Bool?
    private var cooldowns: [Key: Cooldown] = [:]
    private var nextCooldownExpiry: TimeInterval?

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
            } else if clock.now() >= entry.deadline {
                expire(key, id: entry.id)
                queueAfterTeardown(key, waiter: waiter, deadline: deadline, continuation: continuation, operation: operation)
            } else {
                entries[key]?.waiters[waiter] = continuation
                if deadline < entry.deadline {
                    entries[key]?.deadline = deadline
                    entries[key]?.timer?.cancel()
                    armTimer(key, id: entry.id, deadline: deadline)
                }
            }
            return
        }
        let now = seconds(clock.now())
        if let nextCooldownExpiry, now >= nextCooldownExpiry {
            cooldowns = cooldowns.filter { $0.value.until > now }
            self.nextCooldownExpiry = cooldowns.values.map(\.until).min()
        }
        if let cooldown = cooldowns[key] {
            continuation.resume(returning: cooldown.response)
            return
        }
        startEntry(key, id: UUID(), deadline: deadline, waiters: [waiter: continuation], operation: operation)
    }

    private func startEntry(
        _ key: Key, id: UUID, deadline: Duration, waiters: [UUID: CheckedContinuation<Response, Error>],
        operation: @escaping @Sendable () async throws -> Response
    ) {
        if clock.now() >= deadline || isOnline == false {
            let error = URLError(isOnline == false ? .notConnectedToInternet : .timedOut)
            for waiter in waiters.values { waiter.resume(throwing: error) }
            return
        }
        if let cooldown = cooldowns[key], cooldown.until > seconds(clock.now()) {
            for waiter in waiters.values { waiter.resume(returning: cooldown.response) }
            return
        }
        entries[key] = Entry(id: id, deadline: deadline, waiters: waiters, operation: operation)
        startWork(key, id: id, operation: operation)
        armTimer(key, id: id, deadline: deadline)
    }

    private func armTimer(_ key: Key, id: UUID, deadline: Duration) {
        entries[key]?.timer = Task { [weak self, clock] in
            do { try await clock.sleepUntil(deadline) } catch { return }
            await self?.expire(key, id: id)
        }
    }

    private func queueAfterTeardown(
        _ key: Key, waiter: UUID, deadline: Duration, continuation: CheckedContinuation<Response, Error>,
        operation: @escaping @Sendable () async throws -> Response
    ) {
        if let pending = entries[key]?.pending, clock.now() >= pending.deadline {
            expirePending(key, id: pending.id)
        }
        if let pending = entries[key]?.pending {
            entries[key]?.pending?.waiters[waiter] = continuation
            if deadline < pending.deadline {
                entries[key]?.pending?.deadline = deadline
                entries[key]?.pending?.timer?.cancel()
                armPendingTimer(key, id: pending.id, deadline: deadline)
            }
            return
        }
        let id = UUID()
        entries[key]?.pending = Pending(id: id, deadline: deadline, waiters: [waiter: continuation], operation: operation)
        armPendingTimer(key, id: id, deadline: deadline)
    }

    private func armPendingTimer(_ key: Key, id: UUID, deadline: Duration) {
        entries[key]?.pending?.timer = Task { [weak self, clock] in
            do { try await clock.sleepUntil(deadline) } catch { return }
            await self?.expirePending(key, id: id)
        }
    }

    private func expirePending(_ key: Key, id: UUID, error: URLError = URLError(.timedOut)) {
        guard let pending = entries[key]?.pending, pending.id == id else { return }
        entries[key]?.pending = nil
        pending.timer?.cancel()
        for waiter in pending.waiters.values { waiter.resume(throwing: error) }
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

    /// A completed mutation invalidates any read that started before it. Its
    /// readers share one trailing pass, within the original operation budget.
    func invalidate() {
        for key in entries.keys { entries[key]?.invalidated = true }
    }

    /// Retains the server's minimum retry time across cancellation and later
    /// polls. When it exceeds this operation's remaining budget, return the
    /// original 429 now; future reads receive that response until retry is legal.
    func noteRetryAfter(_ key: Key, seconds: TimeInterval, response: Response) -> Bool {
        // Retry-After can contain Int.max seconds. Keep that distant deadline
        // as a monotonic floating-point instant rather than overflowing Duration.
        let until = self.seconds(clock.now()) + seconds
        if until > (cooldowns[key]?.until ?? 0) {
            cooldowns[key] = Cooldown(until: until, response: response)
            nextCooldownExpiry = min(nextCooldownExpiry ?? until, until)
        }
        guard let entry = entries[key], entry.terminalError == nil else { return false }
        return until < self.seconds(entry.deadline)
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func cancel(_ key: Key, waiter: UUID) {
        guard let continuation = entries[key]?.waiters.removeValue(forKey: waiter) else {
            if let continuation = entries[key]?.pending?.waiters.removeValue(forKey: waiter) {
                continuation.resume(throwing: CancellationError())
                if entries[key]?.pending?.waiters.isEmpty == true {
                    entries[key]?.pending?.timer?.cancel()
                    entries[key]?.pending = nil
                }
            }
            return
        }
        continuation.resume(throwing: CancellationError())
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
        for continuation in entry.waiters.values { continuation.resume(throwing: error) }
    }

    private func finish(_ key: Key, id: UUID, result: Result<Response, Error>) {
        guard let entry = entries[key], entry.id == id else { return }
        // A response may run before the expired timer after sleep/wake. The
        // monotonic deadline decides the outcome, not executor delivery order.
        if clock.now() >= entry.deadline { expire(key, id: id) }
        if entry.invalidated, entries[key]?.terminalError == nil,
           case .success(let response) = result, (200...299).contains(response.http.statusCode) {
            entries[key]?.invalidated = false
            startWork(key, id: id, operation: entry.operation)
            return
        }
        guard let completed = entries.removeValue(forKey: key) else { return }
        completed.timer?.cancel()
        for continuation in completed.waiters.values { continuation.resume(with: result) }
        if let pending = completed.pending {
            pending.timer?.cancel()
            startEntry(key, id: pending.id, deadline: pending.deadline, waiters: pending.waiters, operation: pending.operation)
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
            for continuation in entry.waiters.values { continuation.resume(throwing: CancellationError()) }
            if let pending = entry.pending {
                pending.timer?.cancel()
                for waiter in pending.waiters.values { waiter.resume(throwing: CancellationError()) }
            }
        }
    }
}
