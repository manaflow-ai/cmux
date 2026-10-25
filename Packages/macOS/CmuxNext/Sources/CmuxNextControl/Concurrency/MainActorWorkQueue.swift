public import CmuxNextSettings
import CmuxNextCompat
public import CmuxNextWakeups

/// The one path from the control socket to main-actor state
/// (plans/cmux-next/architecture.md section 5a).
///
/// - Bounded: beyond `maxPending` queued requests (or `maxPendingPerConnection`
///   for one client) a request fails at once with `busy` and never runs.
/// - Fair: FIFO within a connection, round-robin across connections, so a
///   client that floods the queue delays only its own requests.
/// - Frame-budgeted: requests are automation work (``MainWorkClass/automation``)
///   of the app's one main-thread scheduler. With the app's frame source each
///   frame drains requests while ``MainFrameBudget`` lets the class run (never
///   while a person's input is pending; with none, on whatever frame time the
///   higher classes left), at least one per frame; without one (tests) at most
///   `frameBudget`. Then the drain returns to the run loop so input and
///   rendering get the rest of the frame. The first request after idle runs on
///   the next main run loop turn instead of the next display frame
///   (`scheduleSoon`); work left after a drain waits for frames.
/// - Input first, in order: a request of class ``MainWorkClass/input`` (an
///   injected key, `debug.key`) whose connection has nothing queued runs on
///   the next main run loop turn, ahead of other connections' requests, and
///   every budgeted batch yields while it waits. It never passes its own
///   connection's earlier requests: behind them it waits its turn like any
///   request, so a client that pipelines a focus change and then a key types
///   into the surface it focused. Each input turn runs only the input queued
///   before it, so a client that keeps injecting keys cannot hold the main
///   thread, and input counts in the per-connection limit.
/// - Deadlined: every request carries a deadline. One that expires while
///   queued fails with `timeout` and is dropped without running. Time the
///   main thread spends in Chromium's start does not count
///   (`MainThreadEngineStart`).
public final class MainActorWorkQueue: Sendable {
    public struct Limits: Sendable {
        public var maxPending: Int
        public var maxPendingPerConnection: Int
        public var frameBudget: Duration

        public init(maxPending: Int = 1_024, maxPendingPerConnection: Int = 256, frameBudget: Duration = .milliseconds(4)) {
            self.maxPending = maxPending
            self.maxPendingPerConnection = maxPendingPerConnection
            self.frameBudget = frameBudget
        }
    }

    /// Counters for `debug.queue` and the CLI storm bench.
    public struct Stats: Sendable, Equatable {
        public var pending = 0
        public var peakPending = 0
        public var executed = 0
        public var expired = 0
        public var rejectedBusy = 0
        public var frames = 0
        /// Frames whose work exceeded the budget (one long item).
        public var overBudgetFrames = 0
        public var maxFrameWork: Duration = .zero
        public var totalWork: Duration = .zero
        /// Longest time an item waited between enqueue and running.
        public var maxQueueWait: Duration = .zero

        public var json: JSONValue {
            [
                "pending": JSONValue(pending), "peak_pending": JSONValue(peakPending), "executed": JSONValue(executed),
                "expired": JSONValue(expired), "rejected_busy": JSONValue(rejectedBusy), "frames": JSONValue(frames),
                "over_budget_frames": JSONValue(overBudgetFrames),
                "max_frame_work_ms": .number(maxFrameWork.fractionalMilliseconds),
                "total_work_ms": .number(totalWork.fractionalMilliseconds),
                "max_queue_wait_ms": .number(maxQueueWait.fractionalMilliseconds),
            ]
        }
    }

    private struct ItemQueue {
        var items: [MainActorWorkItem] = []
        var head = 0
        var count: Int { items.count - head }
        var first: MainActorWorkItem? { items[checked: head] }

        mutating func popFirst() -> MainActorWorkItem? {
            guard let item = items[checked: head] else { return nil }
            head += 1
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            }
            return item
        }
    }

    private struct State {
        /// Every queued item, FIFO per connection (injected input included).
        var queues: [ControlConnectionID: ItemQueue] = [:]
        /// Connections with queued items, in round-robin order.
        var ready: [ControlConnectionID] = []
        /// Injected input that was queued at the head of its connection, in arrival order: the
        /// next input turn runs these ahead of other connections' requests.
        var urgent: [UrgentInput] = []
        var inputDrainPending = false
        var framePending = false
        var stats = Stats()
        var afterFrame: (@MainActor @Sendable () -> Void)?
    }

    private struct UrgentInput {
        let connection: ControlConnectionID
        let item: MainActorWorkItem
    }

    private enum Drain {
        case input, frame
    }

    public let limits: Limits
    private let frameSource: any ControlFrameSource
    private let state = Mutex(State())

    public init(limits: Limits = Limits(), frameSource: any ControlFrameSource = MainQueueFrameSource()) {
        self.limits = limits
        self.frameSource = frameSource
    }

    public var stats: Stats { state.withLock { $0.stats } }

    /// `method` interned on the app's board (nil without one): the router calls it once per method
    /// when it registers the method, so a request reaches ``run(connection:method:owner:workClass:deadline:countingFrom:_:)``
    /// with its owner and takes neither the board's owners lock nor a string hash.
    public func owner(of method: String) -> MainTaskOwner? {
        frameSource.mainTaskBoard?.owner(method)
    }

    public func resetStats() {
        state.withLock { state in
            let pending = state.stats.pending
            state.stats = Stats()
            state.stats.pending = pending
        }
    }

    /// Called on the main actor after a frame that ran at least one item, inside that frame's
    /// drain: the control snapshot marks itself stale there.
    public func setAfterFrame(_ hook: (@MainActor @Sendable () -> Void)?) {
        state.withLock { $0.afterFrame = hook }
    }

    /// Queues `work` for the main actor and returns its result. Throws
    /// `busy` at once when the queue is full, `timeout` when `deadline`
    /// passes before `work` starts, or whatever `work` throws.
    public func run<T: Sendable>(
        connection: ControlConnectionID = .inProcess,
        method: String,
        owner: MainTaskOwner? = nil,
        workClass: MainWorkClass = .automation,
        deadline: ContinuousClock.Instant,
        countingFrom mark: Duration? = nil,
        _ work: @escaping @MainActor @Sendable () throws -> T
    ) async throws -> T {
        let now = ContinuousClock.now
        let timeout = ControlError.timeout(method, after: max(deadline - now, .zero))
        // Main-thread time in Chromium's start after `mark` does not count
        // (MainThreadEngineStart): an item queued behind CefInitialize runs when it ends.
        let engineStart = MainThreadEngineStart.shared
        let mark = mark ?? engineStart.total
        // Interned when the method was registered; otherwise here, off the main thread. Either way
        // the drain starts the task without a lock.
        let owner = owner ?? frameSource.mainTaskBoard?.owner(method)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let item = MainActorWorkItem(
                connection: connection,
                method: method,
                owner: owner,
                workClass: workClass == .input ? .input : .automation,
                deadline: deadline,
                enqueuedAt: now,
                body: {
                    do {
                        continuation.resume(returning: try work())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                },
                fail: { continuation.resume(throwing: $0) }
            )
            if let rejection = enqueue(item) {
                item.expire(rejection)
                return
            }
            let task = Task { [weak self] in
                // wakeup-allow: one-shot work-item deadline, cancelled when the item runs
                do { try await engineStart.waitPast(deadline, countingFrom: mark) } catch { return }
                if item.expire(timeout) { self?.state.withLock { $0.stats.expired += 1 } }
            }
            item.attachTimer(task)
        }
    }

    // MARK: - Private

    private func enqueue(_ item: MainActorWorkItem) -> ControlError? {
        let board = item.workClass == .input ? frameSource.mainTaskBoard : nil
        let (rejection, drain) = state.withLock { state -> (ControlError?, Drain?) in
            let pending = state.stats.pending
            let mine = state.queues[item.connection]?.count ?? 0
            if pending >= limits.maxPending {
                state.stats.rejectedBusy += 1
                return (.busy(pending: pending, limit: limits.maxPending), nil)
            }
            if mine >= limits.maxPendingPerConnection {
                state.stats.rejectedBusy += 1
                return (.busy(pending: mine, limit: limits.maxPendingPerConnection), nil)
            }
            if mine == 0 { state.ready.append(item.connection) }
            state.queues[item.connection, default: ItemQueue()].items.append(item)
            state.stats.pending += 1
            state.stats.peakPending = max(state.stats.peakPending, state.stats.pending)
            // Injected input goes ahead of other connections only from the head of its own: behind
            // its connection's earlier requests it waits its turn (FIFO within a connection).
            if item.workClass == .input, mine == 0 {
                state.urgent.append(UrgentInput(connection: item.connection, item: item))
                // Counted before it can be claimed: batches yield until it ran or expired.
                if let board { item.countAsPendingInput(on: board) }
                guard !state.inputDrainPending else { return (nil, nil) }
                state.inputDrainPending = true
                return (nil, .input)
            }
            guard !state.framePending else { return (nil, nil) }
            state.framePending = true
            return (nil, .frame)
        }
        // Input runs on the next run loop turn; other work does when the queue was idle until now
        // (not a frame later).
        switch drain {
        case .input: frameSource.scheduleSoon { [self] in drainInput() }
        case .frame: frameSource.scheduleSoon { [self] in drainFrame() }
        case nil: break
        }
        return rejection
    }

    /// Runs the injected input queued at the head of its connection before this turn, unbudgeted,
    /// in arrival order. Input queued while it runs gets the next run loop turn, so a client that
    /// keeps injecting keys returns the main thread to the run loop (events, the commit) between.
    @MainActor
    private func drainInput() {
        let budget = frameSource.mainFrameBudget
        let batch = state.withLock { state -> [UrgentInput] in
            state.inputDrainPending = false
            let batch = state.urgent
            state.urgent.removeAll(keepingCapacity: true)
            return batch
        }
        for urgent in batch {
            guard let item = takeHead(urgent) else { continue }
            let ran: Bool
            if let budget, let owner = item.owner {
                ran = budget.run(.input, owner: owner) { item.run() }
            } else {
                ran = item.run()
            }
            if ran { state.withLock { $0.stats.executed += 1 } }
        }
    }

    /// `urgent`'s item when it is still the head of its connection's queue; nil when a frame drain
    /// ran it already (in its connection's order).
    private func takeHead(_ urgent: UrgentInput) -> MainActorWorkItem? {
        state.withLock { state in
            guard state.queues[urgent.connection]?.first === urgent.item,
                  let item = state.queues[urgent.connection]?.popFirst() else { return nil }
            state.stats.pending -= 1
            if state.queues[urgent.connection]?.count ?? 0 == 0 {
                state.queues[urgent.connection] = nil
                state.ready.removeAll { $0 == urgent.connection }
            }
            return item
        }
    }

    /// Re-arms the drain for the next frame from inside this one (main actor: no run loop hop, so
    /// the app's budgeted frame queue keeps its link; see ``ControlFrameSource/scheduleFrameFromMain(_:)``).
    @MainActor
    private func scheduleDrain() {
        frameSource.scheduleFrameFromMain { [self] in drainFrame() }
    }

    private func popNext() -> MainActorWorkItem? {
        state.withLock { state in
            while !state.ready.isEmpty {
                let connection = state.ready.removeFirst()
                guard let item = state.queues[connection]?.popFirst() else {
                    state.queues[connection] = nil
                    continue
                }
                state.stats.pending -= 1
                if state.queues[connection]?.count ?? 0 > 0 {
                    state.ready.append(connection)
                } else {
                    state.queues[connection] = nil
                }
                return item
            }
            return nil
        }
    }

    @MainActor
    private func drainFrame() {
        let clock = ContinuousClock()
        let start = clock.now
        var ran = 0
        var maxWait: Duration = .zero
        let budget = frameSource.mainFrameBudget
        // With the app's budget: one request at a time while the automation class may run (it
        // yields to a person's pending input and to the frame's visible updates). Without: the
        // queue's own budget, at least one request per drain.
        while budget?.mayRun(.automation) ?? true, let item = popNext() {
            let began = clock.now
            let didRun: Bool
            if let budget, let owner = item.owner {
                // An injected key that waited behind its connection's requests runs as input.
                didRun = budget.run(item.workClass, owner: owner) { item.run() }
            } else {
                didRun = item.run()
            }
            if didRun {
                ran += 1
                maxWait = max(maxWait, began - item.enqueuedAt)
            }
            if budget == nil, clock.now - start >= limits.frameBudget { break }
        }
        let elapsed = clock.now - start
        let (more, hook) = state.withLock { state -> (Bool, (@MainActor @Sendable () -> Void)?) in
            state.stats.frames += 1
            state.stats.executed += ran
            state.stats.totalWork += elapsed
            state.stats.maxFrameWork = max(state.stats.maxFrameWork, elapsed)
            state.stats.maxQueueWait = max(state.stats.maxQueueWait, maxWait)
            if elapsed > limits.frameBudget * 2 { state.stats.overBudgetFrames += 1 }
            let more = state.stats.pending > 0
            if !more { state.framePending = false }
            return (more, ran > 0 ? state.afterFrame : nil)
        }
        // The hook marks the control snapshot stale (ControlSnapshotPublisher: the next read builds it; only a
        // read already waiting on its barrier builds it now). It runs inside this drain's own automation task,
        // so a request storm costs no publish per frame and needs no separate charge.
        hook?()
        if more { scheduleDrain() }
    }
}
