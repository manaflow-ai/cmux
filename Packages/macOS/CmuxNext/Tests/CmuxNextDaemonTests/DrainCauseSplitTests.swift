@testable import CmuxNextDaemon
import CmuxNextCompat
import CmuxNextWakeups
import Testing

/// The frame drain ordered by cause (``DrainTail``): the frame applies every
/// daemon transaction up to and including the last one a person or the frontend caused, in order;
/// the program and automation transactions after it wait in one ordered tail and apply in budgeted
/// tasks of their head's class, whole, in 2 ms slices. A snapshot, and the tail it supersedes,
/// stay in the frame. Read-your-writes waiters advance per transaction.
@MainActor @Suite struct DrainCauseSplitTests {
    /// One workspace, one pane, `tabs` tabs on surfaces 1...tabs titled "old", driven by an
    /// unstarted connection (no socket is touched; a snapshot request fails at once) with `tail`.
    private func makeStore(tabs: Int = 4, tail: (any DrainTailScheduler)?) -> (DaemonStore, StoreDriver) {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: (1...tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "old") })
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-drain-cause-split-test.sock"))
        let driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: NextTurnFrameScheduler(), tail: tail)
        store.driver = driver
        return (store, driver)
    }

    private func title(_ store: DaemonStore, _ surface: Int) -> String? {
        store.tab(surface: SurfaceID(rawValue: UInt64(surface)))?.title
    }

    /// One rename of `surface` to `title` (`tab-renamed`), tagged with `transaction` when given.
    private func rename(_ surface: Int, _ title: String, transaction: String?) -> DaemonEvent {
        let id = SurfaceID(rawValue: UInt64(surface))
        return .tabRenamed(TabDelta(workspace: 1, screen: 1, pane: 1, surface: id, index: nil, entity: TabSnapshot(surface: id, title: title),
                                    clientTransactionID: transaction.map { ClientTransactionID(rawValue: $0) }))
    }

    /// Appends one transaction renaming surfaces 1 and 2 to `title`, with `cause`; returns its last sequence.
    @discardableResult
    private func appendPair(_ driver: StoreDriver, _ sequence: inout UInt64, _ title: String, cause: ObservationCause) -> UInt64 {
        for surface in 1...2 {
            sequence += 1
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: rename(surface, title, transaction: "tx-\(title)"),
                                                        cause: cause))
        }
        return sequence
    }

    /// [auto x100, person]: the frame applies all 101 in order, and nothing is left for a task.
    @Test func aPersonTransactionAfterAHundredAutomationOnesAppliesAllInTheFrameInOrder() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tail: tasks)
        var sequence: UInt64 = 0
        for index in 0..<100 { appendPair(driver, &sequence, "a\(index)", cause: .automation) }
        sequence += 1
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: rename(1, "person", transaction: "mine"), cause: .person))
        store.drain()
        #expect(title(store, 1) == "person", "the person's rename applied before the automation ones the daemon sent first")
        #expect(title(store, 2) == "a99")
        #expect(store.appliedSequence == sequence)
        #expect(store.drainTailCount == 0)
        #expect(tasks.pending == 0, "a task was posted for an empty tail")
    }

    /// [auto x1000]: the frame applies none; each task applies one whole transaction while its
    /// class share is spent, so the storm spreads over tasks and no transaction shows half applied.
    @Test func aThousandAutomationTransactionsSpreadOverTasksWithNoneSplit() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tail: tasks)
        var sequence: UInt64 = 0
        for index in 0..<1000 { appendPair(driver, &sequence, "a\(index)", cause: .automation) }
        store.drain()
        #expect(title(store, 1) == "old", "automation applied in the frame")
        #expect(store.drainTailCount == 1000)
        #expect(tasks.classes == [.automation])
        var runs = 0
        while tasks.runNext() != nil {
            runs += 1
            #expect(title(store, 1) == title(store, 2), "task \(runs) split a transaction")
            #expect(store.drainTailCount == 1000 - runs, "task \(runs) applied more than its one transaction with no share left")
        }
        #expect(runs == 1000)
        #expect(title(store, 1) == "a999")
        #expect(store.appliedSequence == sequence)
    }

    /// With the class share left, a task takes whole transactions until its 2 ms slice ends: the
    /// drain clock moves 300 us a read, so a task applies 7 (its first, then 6 more under 2 ms).
    @Test func aTaskTakesWholeTransactionsForItsTwoMillisecondSlice() throws {
        let tasks = TailTasks()
        tasks.shareLeft = true
        let (store, driver) = makeStore(tail: tasks)
        store.drainClock = SliceClock(step: .microseconds(300))
        var sequence: UInt64 = 0
        for index in 0..<100 { appendPair(driver, &sequence, "a\(index)", cause: .automation) }
        store.drain()
        var left = store.drainTailCount
        while tasks.runNext() != nil {
            let applied = left - store.drainTailCount
            left = store.drainTailCount
            #expect(applied == min(7, applied + left), "a task applied \(applied) transactions")
            #expect(title(store, 1) == title(store, 2), "a slice ended inside a transaction")
        }
        #expect(title(store, 1) == "a99")
    }

    /// Each task runs in its head's class and stops where the class changes: a program's
    /// transaction as visible, an agent's as automation.
    @Test func eachTaskRunsInTheClassOfItsHeadTransaction() throws {
        let tasks = TailTasks()
        tasks.shareLeft = true
        let (store, driver) = makeStore(tail: tasks)
        store.drainClock = SliceClock(step: .microseconds(1))
        let causes: [ObservationCause] = [.program, .automation, .automation, .program]
        for (index, cause) in causes.enumerated() {
            let surface = SurfaceID(rawValue: UInt64(index + 1))
            let event = DaemonEvent.titleChanged(surface: surface, title: "new")
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(index + 1), event: event, cause: cause))
        }
        store.drain()
        #expect(store.drainTailCount == 4)
        #expect(tasks.runNext() == .visible)
        #expect((1...4).map { title(store, $0) } == ["new", "old", "old", "old"])
        #expect(tasks.runNext() == .automation)
        #expect((1...4).map { title(store, $0) } == ["new", "new", "new", "old"])
        #expect(tasks.runNext() == .visible)
        #expect(title(store, 4) == "new")
        #expect(tasks.runNext() == nil)
    }

    /// A waiter for sequence N (inside a transaction) fires once that whole transaction applied, and
    /// never waits on a tail task: the tail through it applies at once, the rest still waits.
    @Test func aWaiterForASequenceInTheTailFiresWithNoTailTask() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tail: tasks)
        var sequence: UInt64 = 0
        var lasts: [UInt64] = []
        for index in 0..<10 { lasts.append(appendPair(driver, &sequence, "a\(index)", cause: .automation)) }
        store.drain()
        let target = lasts[5] - 1  // the first event of transaction 5
        var fired = false
        store.whenApplied(ClientTransactionID(rawValue: "unrelated"), reaching: target) { fired = true }
        #expect(fired, "the person's wait waited on the automation tail")
        #expect(store.appliedSequence == lasts[5], "the wait split its transaction or applied past it")
        #expect(title(store, 1) == "a5")
        #expect(title(store, 2) == "a5")
        #expect(store.drainTailCount == 4)
        var runs = 0
        while tasks.runNext() != nil { runs += 1 }
        #expect(runs == 4)
        #expect(store.appliedSequence == sequence)
    }

    /// ``DaemonStore/waitApplied(atLeast:since:)`` for a sequence in the tail returns reached with
    /// no tail task run.
    @Test func aSequenceWaitForTheTailIsReachedWithNoTailTask() async throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tail: tasks)
        var sequence: UInt64 = 0
        var lasts: [UInt64] = []
        for index in 0..<10 { lasts.append(appendPair(driver, &sequence, "a\(index)", cause: .automation)) }
        store.drain()
        let result = await store.waitApplied(atLeast: lasts[2], since: store.connectionEpoch)
        #expect(result == .reached)
        #expect(store.appliedSequence == lasts[2])
        #expect(store.drainTailCount == 7)
    }

    /// An automation echo a waiter waits for applies in the frame it arrives in, with what is before it.
    @Test func anAwaitedEchoInTheBatchAppliesInTheFrame() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tail: tasks)
        var fired = false
        store.whenApplied(ClientTransactionID(rawValue: "tx-a3")) { fired = true }
        var sequence: UInt64 = 0
        var lasts: [UInt64] = []
        for index in 0..<6 { lasts.append(appendPair(driver, &sequence, "a\(index)", cause: .automation)) }
        store.drain()
        #expect(fired)
        #expect(store.appliedSequence == lasts[3])
        #expect(store.drainTailCount == 2)
    }

    /// A person's transaction that arrives while the tail waits flushes the tail first, in order.
    @Test func aPersonArrivalFlushesTheQueuedTailFirst() throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tail: tasks)
        var sequence: UInt64 = 0
        for index in 0..<5 {
            sequence += 1
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: rename(1, "a\(index)", transaction: nil), cause: .automation))
            sequence += 1
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: .titleChanged(surface: 3, title: "t\(index)"), cause: .automation))
        }
        store.drain()
        #expect(store.drainTailCount > 0)
        #expect(title(store, 1) == "old")
        sequence += 1
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: rename(1, "person", transaction: "mine"), cause: .person))
        store.drain()
        #expect(store.drainTailCount == 0)
        #expect(title(store, 1) == "person", "the person's rename applied before the tail queued ahead of it")
        #expect(title(store, 3) == "t4")
        #expect(store.appliedSequence == sequence)
        while tasks.runNext() != nil {}
        #expect(title(store, 1) == "person", "a task applied the flushed tail again")
    }

    /// An event that asks for a snapshot stays in the frame with everything before it; the tail after
    /// it waits for the snapshot, which applies it in its frame (here the snapshot fails at once).
    @Test func aResyncStaysInTheFrameAndTheTailWaitsForIt() async throws {
        let tasks = TailTasks()
        let (store, driver) = makeStore(tail: tasks)
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: 1, title: "new"), cause: .automation))
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 2, event: .treeChanged(transaction: nil), cause: .program))
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 3, event: .titleChanged(surface: 2, title: "new"), cause: .automation))
        store.drain()
        #expect(title(store, 1) == "new", "the event before the snapshot request waited for a task")
        #expect(store.isResyncing)
        #expect(store.drainTailCount == 1)
        #expect(tasks.pending == 0, "a task was posted while the snapshot is in flight")
        await store.refresh()
        #expect(!store.isResyncing)
        #expect(store.drainTailCount == 0)
        #expect(title(store, 2) == "new", "the tail did not apply after the snapshot")
    }

    /// A tail transaction that needs a snapshot starts it in its task and the rest waits for it.
    @Test func aTailTransactionThatNeedsASnapshotHoldsTheRestForIt() async throws {
        let tasks = TailTasks()
        tasks.shareLeft = true
        let (store, driver) = makeStore(tail: tasks)
        store.drainClock = SliceClock(step: .microseconds(1))
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: 1, title: "new"), cause: .automation))
        // A rename of a surface the store does not hold: its records are out of step.
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 2, event: rename(99, "x", transaction: nil), cause: .automation))
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 3, event: .titleChanged(surface: 2, title: "new"), cause: .automation))
        store.drain()
        #expect(tasks.runNext() == .automation)
        #expect(title(store, 1) == "new")
        #expect(store.isResyncing)
        #expect(title(store, 2) == "old", "the task applied past the transaction that needs a snapshot")
        #expect(tasks.pending == 0)
        await store.refresh()
        #expect(store.drainTailCount == 0)
        #expect(title(store, 2) == "new")
    }

    /// Without a tail scheduler (tests, remote machines, the feature off) the frame applies all.
    @Test func withNoTailSchedulerTheFrameAppliesTheWholeBatch() throws {
        let (store, driver) = makeStore(tail: nil)
        var sequence: UInt64 = 0
        for index in 0..<10 { appendPair(driver, &sequence, "a\(index)", cause: .automation) }
        store.drain()
        #expect(title(store, 1) == "a9")
        #expect(store.drainTailCount == 0)
    }

    /// On the app's scheduler: the tail is one automation post, and each frame applies one slice of
    /// it, so a storm of 1000 spreads over frames, in order, with no transaction split.
    @Test func onTheMainWorkSchedulerTheTailSpreadsOverFrames() throws {
        let clock = FrameClock()
        // The posted work's run loop turns never run: each task runs in a frame.
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: { _ in }) { _ in NoFrameLink() }
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        defer { keeper.deactivate() }
        let (store, driver) = makeStore(tail: work)
        store.drainClock = SliceClock(step: .microseconds(300))
        var sequence: UInt64 = 0
        for index in 0..<1000 { appendPair(driver, &sequence, "a\(index)", cause: .automation) }
        store.drain()
        #expect(work.postedCount(.automation) == 1)
        var frames = 0
        var left = store.drainTailCount
        while left > 0, frames < 1000 {
            frames += 1
            clock.advance(ms: 17)
            work.frameDidFire(timestamp: Double(frames), refreshInterval: 1.0 / 60)
            let applied = left - store.drainTailCount
            left = store.drainTailCount
            #expect(applied <= 7, "frame \(frames) applied \(applied) transactions, past one 2 ms slice")
            #expect(title(store, 1) == title(store, 2), "frame \(frames) split a transaction")
        }
        #expect(frames > 1, "the storm applied in one frame")
        #expect(left == 0)
        #expect(title(store, 1) == "a999")
        #expect(store.appliedSequence == sequence)
    }
}

/// A tail scheduler run by hand: the posted tasks in order, with their classes.
@MainActor
final class TailTasks: DrainTailScheduler {
    private var posts: [(workClass: BudgetedWorkClass, body: @MainActor () -> Void)] = []
    /// Every class posted, in order.
    private(set) var classes: [BudgetedWorkClass] = []
    /// What ``drainTailMayContinue(_:)`` answers: false, a class share spent at once.
    var shareLeft = false

    var pending: Int { posts.count }

    func postDrainTail(_ workClass: BudgetedWorkClass, _ body: @escaping @MainActor () -> Void) {
        posts.append((workClass, body))
        classes.append(workClass)
    }

    func drainTailMayContinue(_ workClass: BudgetedWorkClass) -> Bool { shareLeft }

    /// Runs the oldest posted task; returns its class, nil when none is posted.
    @discardableResult
    func runNext() -> BudgetedWorkClass? {
        guard !posts.isEmpty else { return nil }
        let post = posts.removeFirst()
        post.body()
        return post.workClass
    }
}

/// A clock that moves `step` on every read of `now`.
private final class SliceClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let step: Duration
    private let reads = Mutex(Duration.zero)

    init(step: Duration) {
        self.step = step
    }

    var now: Instant {
        reads.withLock { offset in
            defer { offset += step }
            return Instant(offset: offset)
        }
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()
    }
}

/// The budget's clock: moves only when the test moves it.
@MainActor
private final class FrameClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in now } }
    func advance(ms: Double) { now += UInt64((ms * 1_000_000).rounded()) }
}

@MainActor
private final class NoFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
