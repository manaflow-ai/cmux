import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// `MainDelivery(class:owner:on:)` and the classed run-loop block (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// task 217, R-delivery): a delivery on main runs inline as a task of its class on the board, a
/// delivery from another thread is posted in its class, and a classed `MainRunLoopBlock` is named
/// on the board while it runs.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainDeliveryTests {
    /// On main the work runs before `run` returns, as a task of the delivery's class and owner,
    /// with the delivering line on the board, and its time charged to the class.
    @Test func anInlineDeliveryIsATaskOnTheBoard() {
        let clock = DeliveryClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in DeliveryFakeLink() }
        let delivery = MainDelivery(class: .visible, owner: "browser.tab.kvo", on: work)
        let seen = DeliverySeen()
        let line: UInt = #line + 1
        delivery.run { seen.record(work.board.running) }
        #expect(seen.tasks.count == 1, "an inline delivery ran after run returned")
        let task = seen.tasks.first ?? nil
        #expect(task?.workClass == .visible)
        #expect(task?.owner == "browser.tab.kvo")
        #expect(task?.postedFrom == MainTaskBoard.PostedFrom(file: "CmuxNextControlTests/MainDeliveryTests.swift", line: line))
        #expect(work.board.running == nil, "the task stayed on the board after it returned")
        #expect(work.budget.stats.tasks == [1, 0, 0, 0], "the visible class was not charged with the delivery")
        let row = work.board.ownerSnapshot().owners.first { $0.owner == "browser.tab.kvo" }
        #expect(row?.workClass == .visible)
        #expect(row?.tasks == 1, "the owner ledger did not record the inline delivery")
        #expect(row?.wait.maxNanos == 0, "an inline delivery waits for nothing")
        #expect(row?.sites.first?.location == "CmuxNextControlTests/MainDeliveryTests.swift:\(line)")
    }

    /// From another thread the work is posted in its class: it runs on main, named on the board.
    @Test func anOffMainDeliveryIsPostedInItsClass() async {
        let clock = DeliveryClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in DeliveryFakeLink() }
        let delivery = MainDelivery(class: .automation, owner: work.board.owner("tab-watcher.url"), on: work)
        let seen = DeliverySeen()
        let line: UInt = #line + 1
        await Task.detached { delivery.run { seen.record(work.board.running, onMain: Thread.isMainThread) } }.value
        spinMainRunLoop(until: { !seen.tasks.isEmpty })
        #expect(seen.onMain == [true])
        let task = seen.tasks.first ?? nil
        #expect(task?.workClass == .automation)
        #expect(task?.owner == "tab-watcher.url")
        #expect(task?.postedFrom == MainTaskBoard.PostedFrom(file: "CmuxNextControlTests/MainDeliveryTests.swift", line: line))
        #expect(work.board.running == nil)
        #expect(work.postedCount(.automation) == 0)
    }

    /// A delivery from inside a scheduled task nests in it: the board names the delivery while it
    /// runs and the outer task again after.
    @Test func aDeliveryInsideAPostedTaskNestsInIt() {
        let clock = DeliveryClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in DeliveryFakeLink() }
        let keeper = DeliveryLinkKeeper(on: work)
        let delivery = MainDelivery(class: .visible, owner: "theme.appearance", on: work)
        let seen = DeliverySeen()
        let innerLine: UInt = #line + 2
        work.post(.automation, owner: "cli.request") {
            delivery.run { seen.record(work.board.running) }
            seen.record(work.board.running)
        }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(seen.tasks.map { $0?.owner } == ["theme.appearance", "cli.request"])
        #expect(seen.tasks.map { $0?.workClass } == [.visible, .automation])
        #expect(seen.tasks.first??.postedFrom?.line == innerLine, "the board did not name the inner delivery's site")
        #expect(seen.tasks.last??.postedFrom?.line != innerLine, "the outer task showed the inner delivery's site")
        keeper.stop()
    }

    /// A delivery during a person's action (KVO or a notification the action caused) gives the board
    /// back to the action's span when it returns, with the span's hang scope moved out by the
    /// delivery's time, so a stall later in the action is still the action's.
    @Test func anInlineDeliveryInsideAnActionSpanGivesTheBoardBackToTheSpan() {
        let clock = DeliveryClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in DeliveryFakeLink() }
        let board = work.board
        let delivery = MainDelivery(class: .visible, owner: "browser.tab.kvo", on: work)
        let seen = DeliverySeen()
        let start = clock.now
        let token = board.beginSpan(.input, owner: board.internOwner("tab.close"), budgetNanos: 10_000_000, startNanos: start)
        delivery.run {
            seen.record(board.running)
            clock.advance(5_000_000)
        }
        #expect(seen.tasks.map { $0?.owner } == ["browser.tab.kvo"])
        #expect(board.running?.owner == "tab.close", "the board lost the action span after the delivery")
        #expect(board.running?.workClass == .input)
        #expect(board.running?.startNanos == start)
        #expect(board.hangScope.deadlineNanos == MainTaskBoard.hangScopeEnd(.input, startNanos: start) + 5_000_000,
                "the span's hang scope did not move out by the delivery's time")
        board.endSpan(token, nowNanos: clock.now)
        #expect(board.running == nil)
    }

    /// Inside a scheduled task, a span and a delivery in it: the board names the span after the
    /// delivery and the task after the span, and the task's hang scope moves out by the span's time
    /// once only (the delivery's time is in the span's).
    @Test func aDeliveryInASpanInATaskGivesTheBoardBackInOrder() {
        let clock = DeliveryClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in DeliveryFakeLink() }
        let board = work.board
        let delivery = MainDelivery(class: .visible, owner: "theme.appearance", on: work)
        let seen = DeliverySeen()
        var deadlines: [UInt64] = []
        let taskStart = clock.now
        work.budget.run(.automation, owner: board.owner("cli.request")) {
            let token = board.beginSpan(.input, owner: board.internOwner("pane.split"), budgetNanos: 10_000_000, startNanos: clock.now)
            delivery.run { clock.advance(2_000_000) }
            seen.record(board.running)
            clock.advance(3_000_000)
            board.endSpan(token, nowNanos: clock.now)
            seen.record(board.running)
            work.budget.run(.background, owner: board.owner("index.flush")) { clock.advance(1_000_000) }
            seen.record(board.running)
            deadlines.append(board.hangScope.deadlineNanos)
        }
        #expect(seen.tasks.map { $0?.owner } == ["pane.split", "cli.request", "cli.request"])
        #expect(deadlines == [MainTaskBoard.hangScopeEnd(.automation, startNanos: taskStart) + 6_000_000],
                "the task's hang scope did not move out by the span (5 ms) and the nested task (1 ms) exactly")
        #expect(board.running == nil)
    }

    /// An inline delivery cannot wait, so it takes no turn of its class's pacing: in a typing
    /// burst a due posted request of its class still runs, and a request that delivers inline is
    /// still the request the burst counts.
    @Test func anInlineDeliveryTakesNoBurstSlotOfItsClass() {
        let clock = DeliveryClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in DeliveryFakeLink() }
        let delivery = MainDelivery(class: .automation, owner: "tab-watcher.url", on: work)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: false)
        clock.advance(100_000_000)
        delivery.run {}
        clock.advance(16_666_667)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.automation), "the inline delivery took the due request's burst slot")
        budget.run(.automation, owner: work.board.owner("cli.request")) { delivery.run {} }
        clock.advance(16_666_667)
        budget.beginFrame(timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.automation), "the request that delivered inline was not counted")
        #expect(budget.stats.waitedForBurstSlot[1] == 1)
    }

    /// An inline delivery is charged to its class but is not the class's first task of the frame:
    /// the first posted task of the class still runs.
    @Test func anInlineDeliveryLeavesItsClassItsFirstTaskOfTheFrame() {
        let clock = DeliveryClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in DeliveryFakeLink() }
        let delivery = MainDelivery(class: .visible, owner: "browser.tab.kvo", on: work)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        delivery.run { clock.advance(10_000_000) }
        #expect(budget.stats.tasks[0] == 1, "the delivery was not charged to its class")
        #expect(budget.mayRun(.visible), "the inline delivery took the class's first task of the frame")
    }

    /// A classed run-loop block still runs in a later run-loop callout, never inline, and the board
    /// names it with its class, owner and the line that built it.
    @Test func aClassedRunLoopBlockIsNamedOnTheBoard() {
        let clock = DeliveryClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in DeliveryFakeLink() }
        let seen = DeliverySeen()
        let line: UInt = #line + 1
        let block = MainRunLoopBlock(class: .visible, owner: "inspector.read", on: work) { seen.record(work.board.running) }
        block.perform()
        #expect(seen.tasks.isEmpty, "the block ran inline")
        spinMainRunLoop(until: { !seen.tasks.isEmpty })
        let task = seen.tasks.first ?? nil
        #expect(task?.workClass == .visible)
        #expect(task?.owner == "inspector.read")
        #expect(task?.postedFrom == MainTaskBoard.PostedFrom(file: "CmuxNextControlTests/MainDeliveryTests.swift", line: line))
        #expect(work.board.running == nil)
    }

    /// A classed run-loop block's wait counts from `perform`, read on the queuing thread on the
    /// budget's any-thread clock, to the callout that runs it.
    @Test func aClassedRunLoopBlockRecordsItsWaitFromPerform() {
        let clock = DeliveryAnyThreadClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(clock: { clock.read() })) { _ in DeliveryFakeLink() }
        let seen = DeliverySeen()
        MainRunLoopBlock.perform(class: .automation, owner: work.board.owner("menu.popup"), on: work) { seen.record(work.board.running) }
        clock.advance(4_000_000)
        spinMainRunLoop(until: { !seen.tasks.isEmpty })
        let row = work.board.ownerSnapshot().owners.first { $0.owner == "menu.popup" }
        #expect(row?.workClass == .automation)
        #expect(row?.tasks == 1)
        #expect(row?.wait.maxNanos == 4_000_000, "the wait did not count from perform")
    }

    /// The unclassed block keeps running unnamed (the sites the sweeps have not migrated yet).
    @Test func anUnclassedRunLoopBlockIsNotOnTheBoard() {
        let clock = DeliveryClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in DeliveryFakeLink() }
        let seen = DeliverySeen()
        MainRunLoopBlock.perform { seen.record(work.board.running) }
        spinMainRunLoop(until: { !seen.tasks.isEmpty })
        #expect(seen.tasks.count == 1)
        #expect((seen.tasks.first ?? nil) == nil)
        #expect(work.budget.stats.tasks == [0, 0, 0, 0])
    }

    /// Runs main run loop passes until `done` or 5 s.
    private func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

/// What the delivered work saw on the board, in order.
@MainActor
private final class DeliverySeen {
    var tasks: [MainTaskBoard.Task?] = []
    var onMain: [Bool] = []

    func record(_ task: MainTaskBoard.Task?, onMain main: Bool = true) {
        tasks.append(task)
        onMain.append(main)
    }
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class DeliveryLinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class DeliveryClock {
    private(set) var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }

    func advance(_ nanos: UInt64) { now += nanos }
}

/// A clock any thread reads (the budget's ``MainFrameBudget/postClock``); the test moves it.
private final class DeliveryAnyThreadClock: Sendable {
    private let now = Atomic<UInt64>(1_000_000_000)

    func read() -> UInt64 { now.load(ordering: .acquiring) }

    func advance(_ nanos: UInt64) { _ = now.add(nanos, ordering: .acquiringAndReleasing) }
}

@MainActor
private final class DeliveryFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
