import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

extension BackgroundWork {
    /// A new ``WorkSequence`` on `lane`: its items run in post order, never two at once, each on whichever
    /// slot of the lane is free. Use one per file or store whose writes must not reorder or overlap.
    ///
    /// - Parameters:
    ///   - label: names the sequence in descriptions and traces.
    ///   - lane: the kind of blocking work its items do; default ``BlockingLane/files``.
    public func sequence(_ label: String, mayBlock lane: BlockingLane = .files) -> WorkSequence {
        WorkSequence(label: label, lane: lane, work: self)
    }
}

/// Off-main work that runs in post order, one item at a time, on any free slot of its lane: Chrome's
/// `SequencedTaskRunner` on the thread pool (base/task/sequenced_task_runner.h). Chrome's thread group queues
/// a `Sequence` (base/task/thread_pool/sequence.cc) while it has a task that is not running; here the sequence
/// hands its front item to the lane and the next one when that item ends. Ordered work so needs no thread and
/// no serial slot of its own, and unordered work of the same priority runs beside it.
///
/// Each item states its own priority and ``ShutdownBehavior``. The front item runs at the highest priority of
/// the items behind it, and the best-effort fence does not hold it while one of them is awaited, so an item
/// someone waits for never waits behind lower work at a lower QoS (Chrome raises a whole sequence:
/// `UpdateableSequencedTaskRunner::UpdatePriority`). A raise moves a queued front item to its new level at
/// once, ahead of the work posted after it there; a running one keeps its QoS. The lane reports each item's run
/// (`onRan`) at the level it ran at.
///
/// Cancel and shutdown keep the order of what is left: a cancelled awaited item leaves the queue, and an item
/// that shutdown drops is abandoned in its turn, so a block-shutdown save behind it still runs.
///
/// ```swift
/// let saves = work.sequence("settings.save")
/// saves.post(.bestEffort, shutdown: .blockShutdown) { try? data.write(to: url, options: .atomic) }
/// let text = try await saves.run(.userBlocking) { try String(contentsOf: url) }  // after the save
/// ```
public final class WorkSequence: Sendable, CustomStringConvertible {
    /// The sequence's name, in its items' records.
    public let label: String
    /// The lane every item runs on.
    public let lane: BlockingLane
    private let work: BackgroundWork
    private let scheduler: LaneScheduler
    // concurrency-allow: a short non-blocking critical section over the waiting items and the front, taken by posters, cancel handlers and lane threads that must not await (lock carve-out); under it at most one LaneScheduler submit, move or remove, which takes only the lane's lock, and the lane never takes this one.
    private let state = Mutex(State())

    init(label: String, lane: BlockingLane, work: BackgroundWork) {
        self.label = label
        self.lane = lane
        self.work = work
        scheduler = work.lanes[lane.rawValue]
    }

    public var description: String { "\(label) (\(lane))" }

    private struct Item {
        let job: LaneJob
        let priority: WorkPriority
        /// Nobody awaits it.
        let posted: Bool
        /// The trace clock at its post to the sequence while the `task` category recorded (nil when off), so its
        /// `task.run` queue wait includes the time behind the items in front of it.
        let tracedPost: UInt64?
    }

    /// The item the lane holds, queued or running, and what it was submitted at.
    private struct Front {
        let id: UInt64
        var level: WorkPriority
        var posted: Bool
    }

    private struct State {
        /// The items behind the front, in post order, from `head` on; taken entries are nil.
        var waiting: [Item?] = []
        var head = 0
        /// How many waiting items are at each level, by `rawValue`.
        var levels = Array(repeating: 0, count: WorkPriority.allCases.count)
        /// How many waiting items someone awaits.
        var awaited = 0
        var front: Front?
        /// One thread is handing the next item to the lane: a new item only waits.
        var advancing = false

        var highestWaiting: WorkPriority? {
            WorkPriority.allCases.last(where: { levels[$0.rawValue] > 0 })
        }

        mutating func append(_ item: Item) {
            waiting.append(item)
            count(item, by: 1)
        }

        /// The oldest waiting item; amortized O(1).
        mutating func popFirst() -> Item? {
            guard head < waiting.count, let item = waiting[head] else { return nil }
            waiting[head] = nil
            head += 1
            if head == waiting.count {
                waiting.removeAll(keepingCapacity: true)
                head = 0
            } else if head * 2 >= waiting.count {
                waiting.removeFirst(head)
                head = 0
            }
            count(item, by: -1)
            return item
        }

        /// Takes waiting item `id` out of the queue.
        mutating func remove(_ id: UInt64) -> Item? {
            guard let index = waiting[head...].firstIndex(where: { $0?.job.id == id }), let item = waiting[index] else {
                return nil
            }
            waiting.remove(at: index)
            count(item, by: -1)
            return item
        }

        private mutating func count(_ item: Item, by delta: Int) {
            levels[item.priority.rawValue] += delta
            if !item.posted { awaited += delta }
        }
    }

    /// Runs `body` after every item posted before it has ended, at `priority` (boosted to the caller's priority
    /// at the call), and returns its result.
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it; the item runs at the higher of this and the caller's.
    ///   - shutdown: what ``BackgroundWork/shutdown()`` does with it; default ``ShutdownBehavior/skipOnShutdown``.
    ///   - fileID: the caller's `#fileID`, which names a slow block-shutdown item (leave the default).
    ///   - line: the caller's `#line`.
    ///   - body: the blocking work. It runs on a lane thread, never on the cooperative pool.
    /// - Returns: what `body` returns.
    /// - Throws: what `body` throws; `CancellationError` when the caller's task is cancelled before the item
    ///   starts (it then never runs and leaves the sequence), or when shutdown dropped it.
    public func run<T: Sendable>(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                                 fileID: StaticString = #fileID, line: UInt = #line,
                                 _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let site = BackgroundWork.CallSite(fileID: fileID, line: line)
        work.noteAwaited(priority, site: site)
        let id = work.nextID()
        let level = max(priority, WorkPriority(Task.currentPriority))
        let tracedPost = scheduler.postStamp()
        return try await withTaskCancellationHandler {
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
                guard let job = work.makeJob(id: id, lane: lane, shutdown: shutdown, site: site,
                                             work: { continuation.resume(with: Result { try body() }) },
                                             abandoned: { continuation.resume(throwing: CancellationError()) },
                                             finished: { [self] in finished(id) }) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Checked under the sequence's lock, so a cancel either finds the item or stops it here.
                add(Item(job: job, priority: level, posted: false, tracedPost: tracedPost), unless: { Task.isCancelled })
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// Queues `body` behind every item posted before it and returns at once; nothing awaits it, so nothing
    /// boosts it but an awaited item behind it.
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it.
    ///   - shutdown: what ``BackgroundWork/shutdown()`` does with it; one bounded save whose loss loses data
    ///     is ``ShutdownBehavior/blockShutdown``.
    ///   - fileID: the caller's `#fileID`, which names a slow block-shutdown item (leave the default).
    ///   - line: the caller's `#line`.
    ///   - abandoned: runs instead of `body` when shutdown drops the item before it started, or refuses it.
    ///   - body: the blocking work. It runs on a lane thread, never on the cooperative pool.
    public func post(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                     fileID: StaticString = #fileID, line: UInt = #line,
                     abandoned: @escaping @Sendable () -> Void = {}, _ body: @escaping @Sendable () -> Void) {
        let id = work.nextID()
        let tracedPost = scheduler.postStamp()
        guard let job = work.makeJob(id: id, lane: lane, shutdown: shutdown,
                                     site: BackgroundWork.CallSite(fileID: fileID, line: line), work: body,
                                     abandoned: abandoned, finished: { [self] in finished(id) }) else {
            return abandoned()
        }
        add(Item(job: job, priority: priority, posted: true, tracedPost: tracedPost), unless: { false })
    }

    /// What ``add(_:unless:)`` found under the lock.
    private enum Added {
        /// Cancelled before it was queued.
        case refused
        /// The sequence was idle: this item goes to the lane now.
        case first
        /// It waits behind the front, at the sequence's level: the next item goes to the lane at the highest
        /// waiting level.
        case waits(at: WorkPriority)
    }

    private func add(_ item: Item, unless cancelled: () -> Bool) {
        let added = state.withLock { state -> Added in
            if cancelled() { return .refused }
            state.append(item)
            guard state.front != nil || state.advancing else {
                state.advancing = true
                return .first
            }
            raiseFront(&state)
            return .waits(at: state.highestWaiting ?? item.priority)
        }
        switch added {
        case .refused:
            item.job.abandon()
        case .first:
            advance(reportingQueued: true)
        case .waits(let level):
            work.onQueued(lane, level)
        }
    }

    /// Moves a queued front item up to the highest waiting level, and out of the fence while someone awaits an
    /// item behind it, in place (``LaneScheduler/move(_:to:posted:)``): it keeps its place before the work posted
    /// after it. A running front keeps its QoS; a front shutdown dropped is abandoned, and its `finished` takes
    /// the next. Under the lock.
    private func raiseFront(_ state: inout State) {
        guard var front = state.front else { return }
        let level = max(front.level, state.highestWaiting ?? front.level)
        let posted = front.posted && state.awaited == 0
        guard level != front.level || posted != front.posted, scheduler.move(front.id, to: level, posted: posted) else { return }
        front.level = level
        front.posted = posted
        state.front = front
    }

    /// One step of ``advance(reportingQueued:)``.
    private enum Step {
        case done
        case queued(WorkPriority)
        /// The lane refused this item (shut down): abandon it and take the next.
        case refused(LaneJob)
    }

    /// Hands the oldest waiting item to the lane, at the highest waiting level; an item the lane refuses is
    /// abandoned and the next one goes. The caller set `advancing`. `reportingQueued`: the first item was
    /// not reported as queued yet (it came to an idle sequence).
    private func advance(reportingQueued: Bool = false) {
        var reports = reportingQueued
        while true {
            let step = state.withLock { state -> Step in
                guard state.front == nil, let next = state.popFirst() else {
                    state.advancing = false
                    return .done
                }
                let level = max(next.priority, state.highestWaiting ?? next.priority)
                let posted = next.posted && state.awaited == 0
                // Submitted under this lock: the item's `finished` takes it, so it sees the front set below.
                let submitted = scheduler.submit(next.job, at: level, posted: posted, postStamp: .taken(next.tracedPost),
                                                 unless: { false })
                if case .refused = submitted { return .refused(next.job) }
                state.front = Front(id: next.job.id, level: level, posted: posted)
                state.advancing = false
                if case .queued(let queuedAt) = submitted { return .queued(queuedAt) }
                return .done
            }
            switch step {
            case .done:
                return
            case .queued(let level):
                if reports { work.onQueued(lane, level) }
                return
            case .refused(let job):
                // Not the front, so its `finished` starts nothing; this loop takes the next item.
                job.abandon()
                reports = false
            }
        }
    }

    /// Item `id` ran or was abandoned: when it was the front, the next item goes to the lane.
    private func finished(_ id: UInt64) {
        let next = state.withLock { state -> Bool in
            guard state.front?.id == id else { return false }
            state.front = nil
            state.advancing = true
            return true
        }
        if next { advance() }
    }

    /// The caller's task was cancelled: a waiting item leaves the queue, a front item the lane still queues
    /// leaves the lane (its `finished` then starts the next); a running item runs to its end.
    private func cancel(_ id: UInt64) {
        let job = state.withLock { state -> LaneJob? in
            if let item = state.remove(id) { return item.job }
            guard state.front?.id == id else { return nil }
            return scheduler.remove(id)
        }
        job?.abandon()
    }
}
