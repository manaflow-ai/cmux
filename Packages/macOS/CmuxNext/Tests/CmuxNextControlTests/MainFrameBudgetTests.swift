@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// The one main-thread scheduler's per-frame budget (plans/cmux-next/main-thread-budget.md):
/// class order, per-frame budgets, the yield to pending input, nesting, the watchdog's board.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainFrameBudgetTests {
    @Test func theFirstTaskOfAFrameRunsAndTheRestWaitForTheNextFrame() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.visible))
        // One task longer than the whole 2.5 ms visible budget.
        budget.run(.visible, owner: "store") { clock.advance(ms: 3) }
        #expect(!budget.mayRun(.visible), "the budget is spent: the next task waits for the next frame")
        // Classes have their own budgets: automation still runs this frame.
        #expect(budget.mayRun(.automation))
        // Frame-locked work and input are never held.
        #expect(budget.mayRun(.frame))
        #expect(budget.mayRun(.input))
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.visible), "the next frame's first task always runs")
        #expect(budget.stats.overBudgetTasks[0] == 1)
        #expect(budget.stats.deferredOverBudget[0] == 1)
    }

    @Test func aSecondCallForTheSameVsyncKeepsTheWindow() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 5, refreshInterval: 1.0 / 60)
        budget.run(.visible, owner: "store") { clock.advance(ms: 3) }
        // Another window's display link ticks for the same vsync.
        budget.beginFrame(timestamp: 5, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.visible))
    }

    @Test func aTaskOutsideAnyTickStartsAFreshWindowAfterAFrame() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.run(.automation, owner: "control") { clock.advance(ms: 2) }
        #expect(!budget.mayRun(.automation))
        clock.advance(ms: 17)
        #expect(budget.mayRun(.automation), "a request on an idle queue a frame later has a fresh budget")
    }

    @Test func budgetedClassesYieldToPendingInputButNotTwoFramesInARow() {
        let clock = BudgetClock()
        let input = FakeInputPending()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        input.pending = true
        #expect(!budget.mayRun(.visible), "a pending key is dispatched before the batch")
        #expect(!budget.mayRun(.automation))
        #expect(budget.mayRun(.frame), "frame-locked work never yields")
        clock.advance(ms: 17)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        // Still typing: the batch held last frame runs now, so typing never starves visible updates.
        #expect(budget.mayRun(.visible))
        clock.advance(ms: 17)
        budget.beginFrame(timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.visible), "it ran last frame, so a key still pending holds it again")
        #expect(budget.stats.yieldedToInput[0] == 2)
    }

    @Test func injectedInputQueuedOffMainMakesBatchesYield() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.board.inputQueued()
        #expect(!budget.mayRun(.visible))
        budget.board.inputDone()
        clock.advance(ms: 17)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.visible))
    }

    @Test func aNestedTaskIsPublishedAndChargedAsItself() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        var inner: MainTaskBoard.Task?
        var outerAfterInner: MainTaskBoard.Task?
        budget.run(.visible, owner: "batch") {
            clock.advance(ms: 0.5)
            budget.run(.automation, owner: "workspace.move") {
                inner = budget.board.running
                clock.advance(ms: 2)
            }
            outerAfterInner = budget.board.running
            clock.advance(ms: 0.5)
        }
        #expect(inner?.owner == "workspace.move")
        #expect(inner?.workClass == .automation)
        #expect(outerAfterInner?.owner == "batch", "the outer task is named again once the inner one returns")
        #expect(budget.board.running == nil)
        // The visible batch paid 1 ms of its own, the automation request 2 ms.
        #expect(budget.stats.maxTaskNanos[0] == 1_000_000)
        #expect(budget.stats.maxTaskNanos[1] == 2_000_000)
        #expect(budget.stats.overBudgetTasks == [0, 1, 0])
    }

    @Test func mayRunInsideATaskCountsItsTimeSoFar() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        var allowed: [Bool] = []
        budget.run(.automation, owner: "Control.frames") {
            for _ in 0..<4 {
                allowed.append(budget.mayRun(.automation))
                budget.run(.automation, owner: "request") { clock.advance(ms: 0.4) }
            }
        }
        // A 1 ms automation budget: three 0.4 ms requests fit before it is spent.
        #expect(allowed == [true, true, true, false])
    }

    @Test func anOverBudgetTaskReachesTheBoardsSink() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let reported = Box<[(String, UInt64)]>([])
        budget.board.setOverBudgetSink { task, nanos in reported.withLock { $0.append((task.owner, nanos)) } }
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.run(.visible, owner: "fast") { clock.advance(ms: 1) }
        budget.run(.visible, owner: "slow") { clock.advance(ms: 9) }
        let rows = reported.withLock { $0 }
        #expect(rows.count == 1)
        #expect(rows.first?.0 == "slow")
        #expect(rows.first?.1 == 9_000_000)
    }

    // MARK: FrameScheduler

    @Test func theSchedulerRunsFrameClientsThenVisibleThenAutomationAndHoldsBatchesForInput() {
        let clock = BudgetClock()
        let input = FakeInputPending()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        let scheduler = FrameScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        var order: [String] = []
        let automation = FrameClient(owner: "automation", budgeted: .automation, on: scheduler) { _, budget in
            budget.run(.automation, owner: "automation") { order.append("automation") }
            return true
        }
        let visible = FrameClient(owner: "visible", budgeted: .visible, on: scheduler) { _, budget in
            budget.run(.visible, owner: "visible") { order.append("visible") }
            return true
        }
        let frame = FrameClient(owner: "spring", on: scheduler) { _ in order.append("frame"); return true }
        automation.activate()
        visible.activate()
        frame.activate()
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(order == ["frame", "visible", "automation"])
        order.removeAll()
        input.pending = true
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(order == ["frame"], "a pending key: batches wait, the spring does not")
        #expect(visible.isActive && automation.isActive, "a held batch stays active for the next frame")
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(order == ["frame", "frame", "visible", "automation"], "held one frame, never two")
        frame.deactivate()
        visible.deactivate()
        automation.deactivate()
    }

    @Test func aBatchQueueRunsItsWorkInOrderUnderTheBudgetAndKeepsTheRestForTheNextFrame() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = FrameScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let queue = FrameBatchQueue(owner: "store", workClass: .visible, scheduler: scheduler)
        var ran: [Int] = []
        for index in 0..<3 { queue.enqueue { ran.append(index); clock.advance(ms: 1.5) } }
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        // 2.5 ms visible budget: 1.5 ms spent after the first, 3 ms after the second.
        #expect(ran == [0, 1])
        #expect(queue.count == 1)
        queue.enqueue { ran.append(3) }
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran == [0, 1, 2, 3], "the held task runs first next frame, ahead of work queued after it")
        #expect(queue.count == 0)
        #expect(budget.board.running == nil)
    }

    // MARK: Control work queue

    /// The lag Lawrence felt (perf-lead.md row 6): an injected key waited behind a CLI storm's
    /// queued requests, round-robin with them and frame-paced. An input request runs on the next
    /// main run loop turn, ahead of every queued request, with no display frame.
    @Test func anInjectedKeyRunsAheadOfQueuedRequestsWithoutAFrame() {
        let budget = MainFrameBudget()
        let frames = BudgetedFrameSource(budget: budget, soonOnRunLoop: true)
        let queue = MainActorWorkQueue(frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(20)
        let end = ContinuousClock.now + .seconds(10)
        // Requests of 2 ms each: the idle queue's first drain runs one (a 1 ms automation budget).
        for index in 0..<40 {
            Task.detached {
                _ = try await queue.run(connection: ControlConnectionID(rawValue: UInt64(index + 1)), method: "workspace.move", deadline: deadline) {
                    spin(for: .milliseconds(2))
                }
            }
        }
        while queue.stats.pending < 40, ContinuousClock.now < end { usleep(1_000) }
        let key = Box<String?>(nil)
        Task.detached {
            let value = try await queue.run(connection: ControlConnectionID(rawValue: 99), method: "debug.key", workClass: .input, deadline: deadline) { "key" }
            key.withLock { $0 = value }
        }
        // No frame fires: only main run loop turns.
        while key.withLock({ $0 }) == nil, ContinuousClock.now < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(key.withLock { $0 } == "key", "the key ran on a main run loop turn, without a frame")
        #expect(queue.stats.pending >= 38, "it ran ahead of the queued requests, which wait for frames")
        while queue.stats.pending > 0, ContinuousClock.now < end {
            frames.fire()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        #expect(queue.stats.pending == 0)
    }

    @Test func queuedRequestsYieldWhileAnInjectedKeyWaits() async throws {
        let budget = MainFrameBudget()
        let frames = BudgetedFrameSource(budget: budget, soonOnRunLoop: false)
        let queue = MainActorWorkQueue(frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(20)
        let ran = Box(0)
        let storm = (0..<5).map { index in
            Task.detached { try await queue.run(connection: ControlConnectionID(rawValue: UInt64(index + 1)), method: "w", deadline: deadline) { ran.withLock { $0 += 1 } } }
        }
        while queue.stats.pending < 5 { await Task.yield() }
        budget.board.inputQueued()
        frames.fire()
        #expect(ran.withLock { $0 } == 0, "while a key waits, the frame's requests yield")
        budget.board.inputDone()
        while queue.stats.pending > 0 {
            frames.fire()
            await Task.yield()
        }
        for task in storm { try await task.value }
        #expect(ran.withLock { $0 } == 5)
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class BudgetClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [unowned self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class FakeInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class FakeFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

private final class Box<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    nonisolated deinit {}
    func withLock<R>(_ body: (inout sending Value) -> sending R) -> sending R { mutex.withLock(body) }
}

/// A frame source with the app's budget: frames fire by hand and run as one automation batch
/// (as the app's control `FrameBatcher` does); `scheduleSoon` hops through the main run loop,
/// or (`soonOnRunLoop: false`) waits for the next hand-fired frame too.
private final class BudgetedFrameSource: ControlFrameSource {
    private let frames = ManualFrameSource()
    nonisolated(unsafe) private let budgetRef: MainFrameBudget // crash-allow: read only on the main actor (mainFrameBudget, fire)
    let mainTaskBoard: MainTaskBoard?
    private let soonOnRunLoop: Bool
    private let tick = Mutex<Double>(0)

    @MainActor init(budget: MainFrameBudget, soonOnRunLoop: Bool) {
        budgetRef = budget
        mainTaskBoard = budget.board
        self.soonOnRunLoop = soonOnRunLoop
    }

    @MainActor var mainFrameBudget: MainFrameBudget? { budgetRef }

    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { frames.scheduleFrame(work) }

    func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void) {
        if soonOnRunLoop { MainRunLoopHop().perform(work) } else { frames.scheduleFrame(work) }
    }

    @MainActor func fire() {
        let timestamp = tick.withLock { $0 += 1; return $0 }
        budgetRef.beginFrame(timestamp: timestamp, refreshInterval: 1.0 / 60)
        // No check here: the queue's own drain must yield (the app's scheduler checks first too).
        budgetRef.run(.automation, owner: "Control.frames") { frames.fire() }
    }
}
