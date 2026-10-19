/// Owns one process census and its progressive enrichment for a fixed host scope.
///
/// Construct once per host/security context and inject into its consumers.
/// There is at most one active provider and one retained census. Enrichment never
/// changes the census generation or start time. Completed storage is replaced by
/// the next census; there is no history or per-scope global registry. An expired result is an error,
/// never a fresh empty process table. PID validation remains the provider's duty.
public actor ProcessSnapshotService<Snapshot: Sendable, Fields: OptionSet & Sendable> {
    private typealias Census = ProcessSnapshotCensus<Snapshot, Fields>
    private typealias Waiter = ProcessSnapshotWaiter<Snapshot, Fields>
    private typealias Operation = ProcessSnapshotOperation<Fields>

    private let now: @Sendable () -> ContinuousClock.Instant
    private let capture: @Sendable () async throws -> Snapshot
    private let enrich: @Sendable (Snapshot, Fields) async throws -> Snapshot
    private var cached: Census?
    private var active: Operation?
    private var generation: UInt64 = 0
    private var operationID: UInt64 = 0
    private var waiters: [UInt64: Waiter] = [:]
    private var nextWaiterID: UInt64 = 0

    /// Creates a bounded service. Providers run on detached utility workers.
    /// - Parameters:
    ///   - now: Monotonic clock; age includes enumeration and enrichment duration.
    ///   - capture: Reads a minimal census with completeness and identity metadata.
    ///   - enrich: Adds only the missing fields without another full census.
    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        capture: @escaping @Sendable () async throws -> Snapshot,
        enrich: @escaping @Sendable (Snapshot, Fields) async throws -> Snapshot
    ) {
        self.now = now
        self.capture = capture
        self.enrich = enrich
    }

    /// Requests a census, suspending while compatible work is already active.
    ///
    /// A cancelled waiter returns promptly. Other waiters retain their work. If
    /// everyone cancels, the worker is cancelled but keeps ownership until it
    /// returns, even when its provider cannot interrupt an in-progress syscall.
    ///
    /// - Parameters:
    ///   - fields: Additional fields required by this consumer; empty is minimal.
    ///   - freshness: A post-request census or an age bound at delivery.
    /// - Returns: The immutable census with the provider's completeness metadata.
    /// - Throws: Cancellation, expiry, overload, or a provider error.
    public func snapshot(fields: Fields, freshness: ProcessSnapshotFreshness) async throws -> Snapshot {
        try Task.checkCancellation()
        let instant = now()
        let minimumGeneration: UInt64
        let maximumAge: Duration?
        switch freshness {
        case .afterRequest:
            minimumGeneration = generation &+ 1
            maximumAge = nil
        case .maximumAge(let age):
            minimumGeneration = 0
            maximumAge = max(.zero, age)
        }
        if let cached, let maximumAge,
           cached.startedAt.duration(to: instant) <= maximumAge,
           cached.fields.isSuperset(of: fields) {
            try Task.checkCancellation()
            return cached.value
        }
        guard waiters.count < 256 else { throw ProcessSnapshotError.overloaded }
        nextWaiterID &+= 1
        let id = nextWaiterID
        return try await withTaskCancellationHandler {
            let value: Snapshot = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = Waiter(
                    fields: fields, minimumGeneration: minimumGeneration,
                    maximumAge: maximumAge, continuation: continuation
                )
                startIfNeeded(at: instant)
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func startIfNeeded(at instant: ContinuousClock.Instant) {
        guard active == nil, !waiters.isEmpty else { return }
        let base: Census?
        var fields = Fields()
        if let cached, waiters.values.contains(where: { $0.accepts(cached, at: instant) }) {
            base = cached
            fields = cached.fields
            for waiter in waiters.values where waiter.accepts(cached, at: instant) {
                fields.formUnion(waiter.fields)
            }
        } else {
            base = nil
            cached = nil
            generation &+= 1
        }
        operationID &+= 1
        let id = operationID
        let requestedFields = fields
        let capture = self.capture
        let enrich = self.enrich
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<Snapshot, any Error>
            do {
                try Task.checkCancellation()
                let value: Snapshot
                if let base {
                    value = try await enrich(base.value, requestedFields.subtracting(base.fields))
                } else {
                    value = try await capture()
                }
                try Task.checkCancellation()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            await self?.finish(id, result: result)
        }
        active = Operation(
            id: id, generation: base?.generation ?? generation,
            startedAt: base?.startedAt ?? instant, fields: fields, task: task
        )
    }

    private func finish(_ id: UInt64, result: Result<Snapshot, any Error>) {
        guard let operation = active, operation.id == id else { return }
        active = nil
        let instant = now()
        if !operation.abandoned {
            switch result {
            case .success(let value):
                let census = Census(
                    value: value, fields: operation.fields,
                    generation: operation.generation, startedAt: operation.startedAt
                )
                cached = census
                for (id, waiter) in waiters where waiter.minimumGeneration <= census.generation {
                    if !waiter.accepts(census, at: instant) {
                        waiters.removeValue(forKey: id)?.continuation.resume(throwing: ProcessSnapshotError.expired)
                    } else if census.fields.isSuperset(of: waiter.fields) {
                        waiters.removeValue(forKey: id)?.continuation.resume(returning: value)
                    }
                }
            case .failure(let error):
                cached = nil
                for (id, waiter) in waiters where waiter.minimumGeneration <= operation.generation {
                    waiters.removeValue(forKey: id)?.continuation.resume(throwing: error)
                }
            }
        } else {
            cached = nil
        }
        startIfNeeded(at: instant)
    }

    private func cancel(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        if waiters.isEmpty, active != nil {
            active?.abandoned = true
            active?.task.cancel()
        }
    }
}
