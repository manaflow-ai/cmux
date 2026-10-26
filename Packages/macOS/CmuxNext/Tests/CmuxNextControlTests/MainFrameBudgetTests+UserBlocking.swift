import CmuxNextWakeups
import Foundation
import Testing

/// The userBlocking class of ``MainFrameBudget`` (p06-scheduler-208, Chrome kUserBlocking in
/// `content/browser/scheduler/browser_task_queues.h`): the rest of a person's action runs before
/// visible work, the input response it answers does not hold it and its commit closes it, and a
/// flood of it is capped at the visible + automation shares with visible progressing.
extension MainFrameBudgetTests {
    @Test func userBlockingRunsBeforeFiftyQueuedVisibleTasks() {
        let clock = BudgetClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: { _ in }) { _ in
            FakeFrameLink()
        }
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        var ran: [String] = []
        for index in 0..<50 {
            work.post(.visible, owner: "sidebar.rows") {
                clock.advance(ms: 0.05)
                ran.append("visible \(index)")
            }
        }
        work.post(.userBlocking, owner: "action.reply") {
            clock.advance(ms: 0.05)
            ran.append("userBlocking")
        }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran.first == "userBlocking", "the person's reply waited behind \(ran.firstIndex(of: "userBlocking") ?? -1) visible tasks")
        #expect(ran.count == 51, "the frame ran \(ran.count) of 51 tasks of 0.05 ms")
        keeper.deactivate()
    }

    @Test func aUserBlockingPostWhileFramesRunRunsOnTheNextTurn() {
        let clock = BudgetClock()
        var turns: [@MainActor () -> Void] = []
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read),
                                             performTurn: { turns.append($0) }) { _ in FakeFrameLink() }
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        var ran: [String] = []
        work.post(.visible, owner: "sidebar.rows") { ran.append("visible") }
        work.post(.userBlocking, owner: "action.reply") { ran.append("userBlocking") }
        #expect(ran.isEmpty, "a post never runs inline")
        #expect(turns.count == 1, "the userBlocking post queued one turn")
        for turn in turns { turn() }
        #expect(ran == ["userBlocking"], "the reply waited for a display frame; visible stays on its frame")
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran == ["userBlocking", "visible"])
        keeper.deactivate()
    }

    @Test func userBlockingRunsWhileItsInputResponseIsOpenAndItsCommitClosesIt() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        #expect(!budget.mayRun(.automation), "the open response holds automation")
        #expect(budget.mayRun(.userBlocking), "the open response held the reply it waits for")
        budget.run(.userBlocking, owner: budget.board.owner("action.reply")) { clock.advance(ms: 1) }
        #expect(budget.mayRun(.userBlocking), "a second reply in the same frame waited for the response")
        #expect(budget.isInputResponseOpen, "the reply has not committed yet")
        // The pass after the reply is its commit; no link tick began since the key.
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen, "the reply's commit did not close the response")
        #expect(budget.mayRun(.automation))
        #expect(budget.stats.yieldedToInputResponse[3] == 0)
        #expect(budget.stats.maxInputResponseNanos == 1_000_000)
        #expect(budget.stats.inputResponseCapHits == 0)
    }

    /// A reply that answered the previous key does not close the response of the key after it.
    @Test func aUserBlockingTaskBeforeANewKeyDoesNotCloseThatKeysResponse() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        budget.run(.userBlocking, owner: budget.board.owner("action.reply")) { clock.advance(ms: 1) }
        budget.noteDiscreteInput(expectsFrame: true)
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "the first key's reply closed the second key's response")
        // A task that ran with no response open has no response to close.
        clock.advance(ms: 17)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen)
        budget.run(.userBlocking, owner: budget.board.owner("action.reply")) { clock.advance(ms: 1) }
        budget.noteDiscreteInput(expectsFrame: true)
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "a reply that ran with no response open closed the next one")
    }

    @Test func theTypingBurstDoesNotRateLimitUserBlocking() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: false)
        var ran = 0
        while budget.mayRun(.userBlocking), ran < 10 {
            budget.run(.userBlocking, owner: budget.board.owner("action.reply")) { clock.advance(ms: 0.1) }
            ran += 1
        }
        #expect(ran == 10, "the burst's one task per 100 ms held the person's replies after \(ran)")
        #expect(budget.stats.waitedForBurstSlot[3] == 0)
    }

    @Test func pendingInputHoldsUserBlockingButNotTwoFramesInARow() {
        let clock = BudgetClock()
        let input = UserBlockingInput()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        input.pending = true
        #expect(!budget.mayRun(.userBlocking), "the person's next key is dispatched before the reply")
        clock.advance(ms: 17)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.userBlocking), "it yielded last frame: typing never starves the reply")
        #expect(budget.stats.yieldedToInput[3] == 1)
    }

    /// With nothing else queued, userBlocking stops at its cap (the visible + automation shares,
    /// 3.5 ms), not at the frame's 4 ms of idle time.
    @Test func userBlockingStopsAtItsCapWithNoIdleTimePastIt() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        #expect(budget.budgets.userBlocking == budget.budgets.visible + budget.budgets.automation)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        var ran = 0
        while budget.mayRun(.userBlocking), ran < 100 {
            budget.run(.userBlocking, owner: budget.board.owner("action.reply")) { clock.advance(ms: 0.5) }
            ran += 1
        }
        #expect(ran == 7, "\(ran) tasks of 0.5 ms ran under a 3.5 ms cap")
        #expect(budget.stats.idleTasks[3] == 0)
        #expect(budget.stats.deferredOverBudget[3] == 1)
    }

    /// A flood of userBlocking work and a visible backlog: userBlocking never runs past its cap
    /// plus one task a frame, visible runs every frame, and at least every second frame it gets its
    /// whole share.
    @Test func aUserBlockingFloodIsCappedAndVisibleProgressesEverySecondFrame() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let reply = budget.board.owner("action.reply"), rows = budget.board.owner("sidebar.rows")
        var perFrame: [(userBlocking: Int, visible: Int)] = []
        for frame in 1...12 {
            budget.beginFrame(timestamp: CFTimeInterval(frame), refreshInterval: 1.0 / 60)
            // The frame scheduler's order: every class in turn, each while it may run.
            var userBlocking = 0, visible = 0
            while budget.mayRun(.userBlocking) {
                budget.run(.userBlocking, owner: reply) { clock.advance(ms: 1) }
                userBlocking += 1
            }
            while budget.mayRun(.visible) {
                budget.run(.visible, owner: rows) { clock.advance(ms: 1) }
                visible += 1
            }
            perFrame.append((userBlocking, visible))
            clock.advance(ms: 17)
        }
        for (frame, ran) in perFrame.enumerated() {
            #expect(ran.userBlocking >= 1, "frame \(frame): the flood made no progress")
            #expect(ran.userBlocking <= 4, "frame \(frame): \(ran.userBlocking) ms of userBlocking past its 3.5 ms cap")
            #expect(ran.visible >= 1, "frame \(frame): visible was starved")
        }
        for pair in stride(from: 0, to: perFrame.count - 1, by: 1) {
            let most = max(perFrame[pair].visible, perFrame[pair + 1].visible)
            #expect(most >= 3, "frames \(pair) and \(pair + 1): visible never got its 2.5 ms share (\(most) tasks of 1 ms)")
        }
        #expect(budget.stats.deferredOverBudget[3] > 0)
    }

    @Test func theCounterSlotsNameEveryBudgetedClassOnce() {
        #expect(Set(MainFrameBudget.Stats.classes) == Set(MainWorkClass.budgeted))
        #expect(MainFrameBudget.Stats.classes.count == MainWorkClass.budgeted.count)
        #expect(MainWorkClass.budgeted.first == .userBlocking, "userBlocking runs first of the budgeted classes")
        #expect(MainWorkClass.userBlocking.isBudgeted)
        #expect(MainWorkClass.userBlocking > .frame && MainWorkClass.userBlocking < .visible)
        #expect(WorkPriority(MainWorkClass.userBlocking) == .userBlocking)
    }
}

@MainActor
private final class UserBlockingInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}
