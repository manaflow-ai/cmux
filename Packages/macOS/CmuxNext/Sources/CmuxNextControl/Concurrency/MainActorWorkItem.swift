import CmuxNextCompat
import CmuxNextWakeups

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
    /// The control method (the watchdog and the `stall.main_task` signpost name the task by it).
    let method: String
    /// Its main-thread priority class: ``MainWorkClass/input`` for injected input, else automation.
    let workClass: MainWorkClass
    let deadline: ContinuousClock.Instant
    let enqueuedAt: ContinuousClock.Instant
    private let body: @MainActor @Sendable () -> Void
    private let fail: @Sendable (ControlError) -> Void
    /// Called once, by whichever of run and expire claims the item (an input item's count on the board).
    private let claimed: @Sendable () -> Void
    private let phase = Mutex(Phase.pending)
    private let timer = Mutex<Task<Void, Never>?>(nil)

    init(
        connection: ControlConnectionID,
        method: String = "",
        workClass: MainWorkClass = .automation,
        deadline: ContinuousClock.Instant,
        enqueuedAt: ContinuousClock.Instant,
        body: @escaping @MainActor @Sendable () -> Void,
        fail: @escaping @Sendable (ControlError) -> Void,
        claimed: @escaping @Sendable () -> Void = {}
    ) {
        self.connection = connection
        self.method = method
        self.workClass = workClass
        self.deadline = deadline
        self.enqueuedAt = enqueuedAt
        self.body = body
        self.fail = fail
        self.claimed = claimed
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
        self.claimed()
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
        if claimed {
            self.claimed()
            fail(error)
        }
        return claimed
    }
}
