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
        // One task longer than the frame's whole 4 ms of scheduled work.
        budget.run(.visible, owner: budget.board.owner("store")) { clock.advance(ms: 4.5) }
        #expect(!budget.mayRun(.visible), "the frame's budget is spent: the next task waits for the next frame")
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
        budget.run(.visible, owner: budget.board.owner("store")) { clock.advance(ms: 4.5) }
        // Another window's display link ticks for the same vsync.
        budget.beginFrame(timestamp: 5, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.visible))
    }

    @Test func aTaskOutsideAnyTickStartsAFreshWindowAfterAFrame() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.run(.automation, owner: budget.board.owner("control")) { clock.advance(ms: 4.5) }
        #expect(!budget.mayRun(.automation))
        clock.advance(ms: 17)
        #expect(budget.mayRun(.automation), "a request on an idle queue a frame later has a fresh budget")
    }

    @Test func aTaskLongerThanAFrameDoesNotResetItsOwnBudget() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        var allowed: [Bool] = []
        budget.run(.visible, owner: budget.board.owner("DaemonStore.drain")) {
            for _ in 0..<3 {
                // One slice of a large batch takes longer than the whole frame.
                budget.run(.visible, owner: budget.board.owner("slice")) { clock.advance(ms: 20) }
                allowed.append(budget.mayRun(.visible))
            }
        }
        #expect(allowed == [false, false, false], "the rest of the batch waits for the next display frame")
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
        budget.run(.visible, owner: budget.board.owner("batch")) {
            clock.advance(ms: 0.5)
            budget.run(.automation, owner: budget.board.owner("workspace.move")) {
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

    /// Idle-time scheduling (Chrome's idle tasks): with no input pending, a class past its own
    /// share uses the frame time the others left, up to the frame's 4 ms of scheduled work. A CLI
    /// storm on an idle main thread runs at the rate the control queue had before the split.
    @Test func withNoInputPendingAClassUsesTheIdleRestOfTheFrame() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        let batch = budget.board.owner("Control.frames"), request = budget.board.owner("request")
        var allowed: [Bool] = []
        budget.run(.automation, owner: batch) {
            for _ in 0..<12 {
                allowed.append(budget.mayRun(.automation))
                budget.run(.automation, owner: request) { clock.advance(ms: 0.4) }
            }
        }
        // 0.4 ms requests: three within the 1 ms share, seven more on idle time, none past 4 ms.
        #expect(allowed == Array(repeating: true, count: 10) + [false, false])
        #expect(budget.stats.idleTasks[1] == 7)
    }

    /// Under input the shares hold: a class that may run (it yielded last frame) keeps to its own.
    @Test func whileInputIsPendingAClassKeepsToItsShare() {
        let clock = BudgetClock()
        let input = FakeInputPending()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        let request = budget.board.owner("request")
        input.pending = true
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.automation), "frame 1: a pending key goes first")
        clock.advance(ms: 17)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        var allowed: [Bool] = []
        for _ in 0..<4 {
            allowed.append(budget.mayRun(.automation))
            budget.run(.automation, owner: request) { clock.advance(ms: 0.4) }
        }
        #expect(allowed == [true, true, true, false], "frame 2: it yielded last frame, so it runs, but only its 1 ms")
        #expect(budget.stats.idleTasks[1] == 0)
    }

    @Test func anOverBudgetTaskReachesTheBoardsSink() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let reported = Box<[(String, UInt64)]>([])
        budget.board.setOverBudgetSink { task, nanos in reported.withLock { $0.append((task.owner, nanos)) } }
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.run(.visible, owner: budget.board.owner("fast")) { clock.advance(ms: 1) }
        budget.run(.visible, owner: budget.board.owner("slow")) { clock.advance(ms: 9) }
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
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        var order: [String] = []
        let automation = FrameClient(owner: "automation", budgeted: .automation, on: scheduler) { _, budget in
            budget.run(.automation, owner: budget.board.owner("automation")) { order.append("automation") }
            return true
        }
        let visible = FrameClient(owner: "visible", budgeted: .visible, on: scheduler) { _, budget in
            budget.run(.visible, owner: budget.board.owner("visible")) { order.append("visible") }
            return true
        }
        let frame = FrameClient(owner: "spring", on: scheduler.frames) { _ in order.append("frame"); return true }
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
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let queue = FrameBatchQueue(owner: "store", budgeted: .visible, on: scheduler)
        var ran: [Int] = []
        for index in 0..<4 { queue.enqueue { ran.append(index); clock.advance(ms: 1.5) } }
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        // 2.5 ms visible share, then idle time to 4 ms: 3 ms spent before the third, 4.5 ms after it.
        #expect(ran == [0, 1, 2])
        #expect(queue.count == 1)
        queue.enqueue { ran.append(4) }
        clock.advance(ms: 17)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran == [0, 1, 2, 3, 4], "the held task runs first next frame, ahead of work queued after it")
        #expect(queue.count == 0)
        #expect(budget.board.running == nil)
    }

    /// A person's action is never budgeted (CLAUDE.md: a slow visible action is fixed by removing
    /// the work, never by delaying it): what it hands a frame queue (the content a tab switch shows)
    /// runs in the next frame however much daemon churn, automation and background work is queued
    /// and while the person keeps typing.
    @Test func workAPersonsActionQueuedRunsInTheNextFrameUnderEveryLoad() {
        let clock = BudgetClock()
        let input = FakeInputPending()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let churn = FrameBatchQueue(owner: "DaemonStore.drain", budgeted: .visible, on: scheduler)
        let agents = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: scheduler)
        let idle = FrameBatchQueue(owner: "background", budgeted: .background, on: scheduler)
        for _ in 0..<50 {
            churn.enqueue { clock.advance(ms: 2) }
            agents.enqueue { clock.advance(ms: 2) }
            idle.enqueue { clock.advance(ms: 2) }
        }
        let action = FrameBatchQueue(owner: "ContentPresentation", scheduler: scheduler.frames)
        var shown = 0
        for frame in 1...5 {
            input.pending = frame.isMultiple(of: 2)
            action.enqueue { shown += 1 }
            clock.advance(ms: 17)
            scheduler.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
            #expect(shown == frame, "frame \(frame): the action's work waited")
        }
    }

    // MARK: Control work queue

    /// The injected stand-in for a key (`debug.key`, what the benches and agents send) waited
    /// behind a CLI storm's queued requests of other connections, round-robin with them and
    /// frame-paced. An input request at the head of its connection runs on the next main run loop
    /// turn, ahead of other connections' queued requests, with no display frame. (A person's key
    /// never went through this queue: its path is the event queue and ``SessionInputPending``,
    /// guarded by SessionInputPendingTests and measured with real keys by sidebar-churn-typing.py
    /// `--input real`.)
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

    /// One saturating client never keeps the others of its class from ticking: the class's budget
    /// goes to the client that ran least recently first.
    @Test func clientsOfOneClassTakeTurnsWhenEachFillsTheBudget() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        var ticks = ["a": 0, "b": 0]
        let clients = ["a", "b"].map { name in
            FrameClient(owner: name, budgeted: .visible, on: scheduler) { _, budget in
                // Each tick is longer than the frame's whole scheduled budget.
                budget.run(.visible, owner: budget.board.owner(name)) { clock.advance(ms: 5) }
                ticks[name, default: 0] += 1
                return true
            }
        }
        for client in clients { client.activate() }
        for frame in 1...4 {
            clock.advance(ms: 17)
            scheduler.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
        }
        #expect(ticks == ["a": 2, "b": 2], "a saturating client starved the other: \(ticks)")
        for client in clients { client.deactivate() }
    }

    /// The budget's window belongs to the one budgeted scheduler: a window's link ticking (another
    /// display, another rate) neither rolls it nor spends it again.
    @Test func aWindowLinkTickDoesNotOpenAnotherBudgetWindow() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let window = FrameScheduler.testing { _ in FakeFrameLink() }
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        spring.activate()
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.run(.visible, owner: budget.board.owner("store")) { clock.advance(ms: 4.5) }
        window.frameDidFire(timestamp: 1.004, refreshInterval: 1.0 / 120)
        #expect(budget.stats.frames == 1)
        #expect(!budget.mayRun(.visible), "the window's tick gave the frame a second budget")
        spring.deactivate()
    }

    /// An idle queue's request outside any tick opens a window and spends the frame's 4 ms; the
    /// link's tick right after it (often in the same run loop pass) keeps that window instead of
    /// giving the pass another 4 ms.
    @Test func aTickRightAfterAnOffTickDrainKeepsItsWindow() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let owner = budget.board.owner("control")
        var ran = 0
        while budget.mayRun(.automation) {
            budget.run(.automation, owner: owner) { clock.advance(ms: 1) }
            ran += 1
        }
        #expect(ran == 4, "the off-tick drain spends the frame's scheduled 4 ms")
        clock.advance(ms: 0.1)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.automation), "the tick 0.1 ms later gave the same pass a second budget")
        clock.advance(ms: 16.7)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.automation), "the next real frame has its budget")
    }

    /// While the budgeted link runs, its ticks own the window: a request outside any tick (a late
    /// tick, a key pending) neither opens a window nor rolls the input-yield memory, so automation
    /// never passes the pending key between two real frames.
    @Test func whileTheLinkRunsAnOffTickRequestOpensNoWindowAndWaitsForTheKey() {
        let clock = BudgetClock()
        let input = FakeInputPending()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let batch = FrameClient(owner: "Control.frames", budgeted: .automation, on: work) { _, _ in true }
        batch.activate()
        input.pending = true
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(budget.stats.yieldedToInput[1] == 1, "the tick held automation for the key")
        // The next tick is late; a request arrives outside any tick first, the key still pending.
        clock.advance(ms: 17)
        #expect(!budget.mayRun(.automation), "an off-tick window let automation run ahead of the pending key")
        #expect(budget.stats.frames == 1)
        clock.advance(ms: 3)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.automation), "held one real frame, never two")
        batch.deactivate()
    }

    /// The commit a frame's requests cause is charged: after a 6 ms render pass (layout, display,
    /// the Core Animation commit of what the requests changed), the next frame's scheduled work
    /// stops at the 2 ms left of the 8 ms pass, not at 4 ms, and a cheap pass gives the 4 ms back.
    @Test func anExpensiveRenderPassLowersTheNextFramesScheduledWork() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let request = budget.board.owner("workspace.move")
        func frame(_ timestamp: Double) -> Int {
            clock.advance(ms: 17)
            budget.beginFrame(timestamp: timestamp, refreshInterval: 1.0 / 60)
            var ran = 0
            while budget.mayRun(.automation) {
                budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
                ran += 1
            }
            return ran
        }
        #expect(frame(1) == 8, "no render pass yet: 4 ms of 0.5 ms requests")
        budget.noteRenderPass(nanos: 6_000_000)
        #expect(frame(2) == 4, "a 6 ms commit leaves 2 ms of the 8 ms pass for the requests")
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(frame(3) == 8, "a cheap commit gives the frame its 4 ms back")
        budget.noteRenderPass(nanos: 9_000_000)
        #expect(frame(4) == 1, "past the whole pass: the first task of a frame still runs")
        #expect(budget.stats.renderPasses == 3)
        #expect(budget.stats.maxRenderPassNanos == 9_000_000)
    }

    /// The pending-input checks between tasks are main-thread work too: their time counts in the
    /// frame's scheduled 4 ms. With 0.25 ms checks and 0.5 ms requests, five run, not eight.
    @Test func thePendingInputChecksCountInTheFramesScheduledWork() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(input: CostlyInputPending(clock: clock, ms: 0.25), uptimeNanos: clock.read)
        let request = budget.board.owner("workspace.move")
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        var ran = 0
        while budget.mayRun(.automation) {
            budget.run(.automation, owner: request) { clock.advance(ms: 0.5) }
            ran += 1
        }
        #expect(ran == 5, "the checks' time was left out of the frame's budget: \(ran) requests ran")
        #expect(budget.stats.maxInputCheckNanos == 250_000)
    }

    /// FIFO within a connection: a client that pipelines a focus change and then a key, without
    /// waiting for the first reply, gets them in that order (the key types into what it focused).
    @Test func anInjectedKeyNeverPassesItsOwnConnectionsEarlierRequest() {
        let budget = MainFrameBudget()
        let frames = BudgetedFrameSource(budget: budget, soonOnRunLoop: true)
        let queue = MainActorWorkQueue(frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(20)
        let end = ContinuousClock.now + .seconds(10)
        let order = Box<[String]>([])
        let client = ControlConnectionID(rawValue: 5)
        Task.detached {
            _ = try await queue.run(connection: client, method: "surface.focus", deadline: deadline) { order.withLock { $0.append("focus") } }
        }
        while queue.stats.pending < 1, ContinuousClock.now < end { usleep(1_000) }
        Task.detached {
            _ = try await queue.run(connection: client, method: "debug.key", workClass: .input, deadline: deadline) { order.withLock { $0.append("key") } }
        }
        while queue.stats.pending < 2, ContinuousClock.now < end { usleep(1_000) }
        while order.withLock({ $0.count }) < 2, ContinuousClock.now < end {
            frames.fire()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        #expect(order.withLock { $0 } == ["focus", "key"])
    }

    /// An input turn runs only the input queued before it: a client that keeps injecting keys
    /// gives the main thread back to the run loop between turns.
    @Test func inputQueuedDuringAnInputTurnWaitsForTheNextTurn() {
        let budget = MainFrameBudget()
        let frames = BudgetedFrameSource(budget: budget, soonOnRunLoop: false)
        let queue = MainActorWorkQueue(frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(20)
        let end = ContinuousClock.now + .seconds(10)
        let ran = Box<[String]>([])
        Task.detached {
            _ = try await queue.run(connection: ControlConnectionID(rawValue: 1), method: "debug.key", workClass: .input, deadline: deadline) {
                ran.withLock { $0.append("a") }
                // Another client's key arrives while this one runs.
                Task.detached {
                    _ = try await queue.run(connection: ControlConnectionID(rawValue: 2), method: "debug.key", workClass: .input, deadline: deadline) {
                        ran.withLock { $0.append("b") }
                    }
                }
                while queue.stats.pending < 1, ContinuousClock.now < end { usleep(100) }
            }
        }
        while queue.stats.pending < 1, ContinuousClock.now < end { usleep(1_000) }
        frames.fire()
        #expect(ran.withLock { $0 } == ["a"], "the key queued during the turn ran in it")
        #expect(queue.stats.pending == 1)
        while queue.stats.pending > 0, ContinuousClock.now < end { frames.fire() }
        #expect(ran.withLock { $0 } == ["a", "b"])
    }

    /// Injected input counts in the per-connection limit: one client cannot queue keys past it.
    @Test func injectedInputCountsInThePerConnectionLimit() async {
        let budget = MainFrameBudget()
        let frames = BudgetedFrameSource(budget: budget, soonOnRunLoop: false)
        let queue = MainActorWorkQueue(limits: .init(maxPending: 100, maxPendingPerConnection: 2), frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(20)
        let client = ControlConnectionID(rawValue: 9)
        let waiting = (0..<2).map { _ in
            Task.detached { try await queue.run(connection: client, method: "debug.key", workClass: .input, deadline: deadline) { 1 } }
        }
        while queue.stats.pending < 2 { await Task.yield() }
        await #expect(throws: ControlError.busy(pending: 2, limit: 2)) {
            try await queue.run(connection: client, method: "debug.key", workClass: .input, deadline: deadline) { 1 }
        }
        while queue.stats.pending > 0 {
            frames.fire()
            await Task.yield()
        }
        for task in waiting { _ = try? await task.value }
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
    // Strong: a scheduler's stall timer can fire after its test returned and read the clock through
    // the budget (fleet 2026-10-25, step 37d7e7e1: an unowned read of a freed clock aborted the suite
    // process, signal 6). The clock holds nothing back, so this makes no cycle.
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class FakeInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// A pending-input check that takes `ms` of main-thread time and finds nothing.
@MainActor
private final class CostlyInputPending: InputPendingSource {
    private let clock: BudgetClock
    private let ms: Double
    init(clock: BudgetClock, ms: Double) {
        self.clock = clock
        self.ms = ms
    }
    func hasPendingInput(uptime: TimeInterval) -> Bool {
        clock.advance(ms: ms)
        return false
    }
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
        budgetRef.run(.automation, owner: budgetRef.board.owner("Control.frames")) { frames.fire() }
    }
}
