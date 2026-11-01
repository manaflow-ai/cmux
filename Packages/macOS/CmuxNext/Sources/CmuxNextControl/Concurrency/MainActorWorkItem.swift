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
    /// ``method`` interned on the app's board off the main thread (nil without one), so running
    /// the item as a scheduled task takes no lock.
    let owner: MainTaskOwner?
    /// Its main-thread priority class: ``MainWorkClass/input`` for injected input, else automation.
    let workClass: MainWorkClass
    let deadline: ContinuousClock.Instant
    let enqueuedAt: ContinuousClock.Instant
    private let body: @MainActor @Sendable () -> Void
    private let fail: @Sendable (ControlError) -> Void
    /// The phase, the deadline timer and the board that counts the item as pending input, under
    /// one lock: claiming the item (run or expire) takes the board and the timer in the same
    /// critical section, so running a request takes two lock operations (claim, finish).
    private let state = Mutex(State())

    private struct State: Sendable {
        var phase = Phase.pending
        var timer: Task<Void, Never>?
        /// The board that counts this item as a person's pending input (an injected key at the
        /// head of its connection), until run or expire claims it.
        var pendingInput: MainTaskBoard?
    }

    init(
        connection: ControlConnectionID,
        method: String = "",
        owner: MainTaskOwner? = nil,
        workClass: MainWorkClass = .automation,
        deadline: ContinuousClock.Instant,
        enqueuedAt: ContinuousClock.Instant,
        body: @escaping @MainActor @Sendable () -> Void,
        fail: @escaping @Sendable (ControlError) -> Void
    ) {
        self.connection = connection
        self.method = method
        self.owner = owner
        self.workClass = workClass
        self.deadline = deadline
        self.enqueuedAt = enqueuedAt
        self.body = body
        self.fail = fail
    }

    var isPending: Bool { state.withLock { $0.phase == .pending } }

    /// Moves a pending item to `phase` and hands back what it held; nil when something else
    /// claimed it first.
    private func claim(_ phase: Phase) -> (timer: Task<Void, Never>?, board: MainTaskBoard?)? {
        state.withLock { state in
            guard state.phase == .pending else { return nil }
            state.phase = phase
            defer { state.timer = nil; state.pendingInput = nil }
            return (state.timer, state.pendingInput)
        }
    }

    /// Runs the body if nothing else claimed the item. Returns false when it
    /// had already expired.
    @MainActor
    func run() -> Bool {
        guard let claimed = claim(.running) else { return false }
        claimed.board?.inputDone()
        claimed.timer?.cancel()
        body()
        state.withLock { $0.phase = .finished }
        return true
    }

    /// Counts the item on `board` as a person's pending input until it runs or expires, so every
    /// budgeted batch yields while it waits. Call before the item can be claimed (while queuing it).
    func countAsPendingInput(on board: MainTaskBoard) {
        board.inputQueued()
        state.withLock { $0.pendingInput = board }
    }

    /// Keeps the deadline timer so running the item cancels it. Cancels it
    /// at once when the item already ran.
    func attachTimer(_ task: Task<Void, Never>) {
        let done = state.withLock { state -> Bool in
            guard state.phase == .pending else { return true }
            state.timer = task
            return false
        }
        if done { task.cancel() }
    }

    /// Fails the item with `error` if it has not started. Returns true when
    /// it did (the item will never run).
    @discardableResult
    func expire(_ error: ControlError) -> Bool {
        guard let claimed = claim(.finished) else { return false }
        claimed.board?.inputDone()
        claimed.timer?.cancel()
        fail(error)
        return true
    }
}
