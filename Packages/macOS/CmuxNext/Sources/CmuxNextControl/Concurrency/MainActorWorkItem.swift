import Synchronization

/// One queued main-actor request. Exactly one of run / expire / cancel wins
/// the `pending` state, so a request that timed out while queued never
/// runs, and a running request is never reported as timed out.
final class MainActorWorkItem: Sendable {
    enum Phase: Sendable {
        case pending
        case running
        case finished
    }

    let connection: ControlConnectionID
    let deadline: ContinuousClock.Instant
    let enqueuedAt: ContinuousClock.Instant
    private let body: @MainActor @Sendable () -> Void
    private let fail: @Sendable (ControlError) -> Void
    private let phase = Mutex(Phase.pending)
    private let timer = Mutex<Task<Void, Never>?>(nil)

    init(
        connection: ControlConnectionID,
        deadline: ContinuousClock.Instant,
        enqueuedAt: ContinuousClock.Instant,
        body: @escaping @MainActor @Sendable () -> Void,
        fail: @escaping @Sendable (ControlError) -> Void
    ) {
        self.connection = connection
        self.deadline = deadline
        self.enqueuedAt = enqueuedAt
        self.body = body
        self.fail = fail
    }

    var isPending: Bool { phase.withLock { $0 == .pending } }

    /// Runs the body if nothing else claimed the item. Returns false when it
    /// had already expired.
    @MainActor
    func run() -> Bool {
        let claimed = phase.withLock { phase -> Bool in
            guard phase == .pending else { return false }
            phase = .running
            return true
        }
        guard claimed else { return false }
        timer.withLock { $0?.cancel() }
        body()
        phase.withLock { $0 = .finished }
        return true
    }

    /// Keeps the deadline timer so running the item cancels it. Cancels it
    /// at once when the item already ran.
    func attachTimer(_ task: Task<Void, Never>) {
        let done = timer.withLock { stored -> Bool in
            stored = task
            return phase.withLock { $0 != .pending }
        }
        if done { task.cancel() }
    }

    /// Fails the item with `error` if it has not started. Returns true when
    /// it did (the item will never run).
    @discardableResult
    func expire(_ error: ControlError) -> Bool {
        let claimed = phase.withLock { phase -> Bool in
            guard phase == .pending else { return false }
            phase = .finished
            return true
        }
        if claimed { fail(error) }
        return claimed
    }
}
