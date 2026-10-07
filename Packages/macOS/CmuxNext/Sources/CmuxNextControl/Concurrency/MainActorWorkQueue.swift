public import CmuxNextSettings
import Synchronization

/// The one path from the control socket to main-actor state
/// (plans/cmux-next/architecture.md section 5a).
///
/// - Bounded: beyond `maxPending` queued requests (or `maxPendingPerConnection`
///   for one client) a request fails at once with `busy` and never runs.
/// - Fair: FIFO within a connection, round-robin across connections, so a
///   client that floods the queue delays only its own requests.
/// - Frame-budgeted: each frame drains at most `frameBudget` of work (at
///   least one item), then returns to the run loop so input and rendering
///   always get the rest of the frame.
/// - Deadlined: every request carries a deadline. One that expires while
///   queued fails with `timeout` and is dropped without running.
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

        mutating func popFirst() -> MainActorWorkItem? {
            guard head < items.count else { return nil }
            let item = items[head]
            head += 1
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            }
            return item
        }
    }

    private struct State {
        var queues: [ControlConnectionID: ItemQueue] = [:]
        /// Connections with queued items, in round-robin order.
        var ready: [ControlConnectionID] = []
        var framePending = false
        var stats = Stats()
        var afterFrame: (@MainActor @Sendable () -> Void)?
    }

    public let limits: Limits
    private let frameSource: any ControlFrameSource
    private let state = Mutex(State())

    public init(limits: Limits = Limits(), frameSource: any ControlFrameSource = MainQueueFrameSource()) {
        self.limits = limits
        self.frameSource = frameSource
    }

    public var stats: Stats { state.withLock { $0.stats } }

    public func resetStats() {
        state.withLock { state in
            let pending = state.stats.pending
            state.stats = Stats()
            state.stats.pending = pending
        }
    }

    /// Called on the main actor after a frame that ran at least one item,
    /// e.g. to republish the control snapshot.
    public func setAfterFrame(_ hook: (@MainActor @Sendable () -> Void)?) {
        state.withLock { $0.afterFrame = hook }
    }

    /// Queues `work` for the main actor and returns its result. Throws
    /// `busy` at once when the queue is full, `timeout` when `deadline`
    /// passes before `work` starts, or whatever `work` throws.
    public func run<T: Sendable>(
        connection: ControlConnectionID = .inProcess,
        method: String,
        deadline: ContinuousClock.Instant,
        _ work: @escaping @MainActor @Sendable () throws -> T
    ) async throws -> T {
        let now = ContinuousClock.now
        let timeout = ControlError.timeout(method, after: max(deadline - now, .zero))
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let item = MainActorWorkItem(
                connection: connection,
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
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                if item.expire(timeout) { self?.state.withLock { $0.stats.expired += 1 } }
            }
            item.attachTimer(task)
        }
    }

    // MARK: - Private

    private func enqueue(_ item: MainActorWorkItem) -> ControlError? {
        let (rejection, schedule) = state.withLock { state -> (ControlError?, Bool) in
            let pending = state.stats.pending
            let mine = state.queues[item.connection]?.count ?? 0
            if pending >= limits.maxPending {
                state.stats.rejectedBusy += 1
                return (.busy(pending: pending, limit: limits.maxPending), false)
            }
            if mine >= limits.maxPendingPerConnection {
                state.stats.rejectedBusy += 1
                return (.busy(pending: mine, limit: limits.maxPendingPerConnection), false)
            }
            if mine == 0 { state.ready.append(item.connection) }
            state.queues[item.connection, default: ItemQueue()].items.append(item)
            state.stats.pending += 1
            state.stats.peakPending = max(state.stats.peakPending, state.stats.pending)
            guard !state.framePending else { return (nil, false) }
            state.framePending = true
            return (nil, true)
        }
        if schedule { scheduleDrain() }
        return rejection
    }

    private func scheduleDrain() {
        frameSource.scheduleFrame { [self] in drainFrame() }
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
        while let item = popNext() {
            let began = clock.now
            if item.run() {
                ran += 1
                maxWait = max(maxWait, began - item.enqueuedAt)
            }
            if clock.now - start >= limits.frameBudget { break }
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
        hook?()
        if more { scheduleDrain() }
    }
}
