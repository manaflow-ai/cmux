import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The userBlocking class of ``MainFrameBudget`` (Chrome kUserBlocking in
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

    @Test func userBlockingRunsWhileItsInputResponseIsOpenAndItsCompletionsCommitClosesIt() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        let key = Self.frameExpectingKey(budget)
        #expect(key != nil, "an action run in a key's dispatch answers that key")
        #expect(!budget.mayRun(.automation), "the open response holds automation")
        #expect(budget.mayRun(.userBlocking), "the open response held the reply it waits for")
        // The key's own turn commits; no link tick began since the key.
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "the key's own commit closed its response")
        budget.run(.userBlocking, owner: budget.board.owner("action.reply")) {
            clock.advance(ms: 1)
            if let key { budget.noteAnswered(key) }
        }
        #expect(budget.mayRun(.userBlocking), "a second reply in the same frame waited for the response")
        #expect(budget.isInputResponseOpen, "the reply has not committed yet")
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen, "the completion's commit did not close the response")
        #expect(budget.mayRun(.automation))
        #expect(budget.stats.yieldedToInputResponse[3] == 0)
        #expect(budget.stats.maxInputResponseNanos == 1_000_000)
        #expect(budget.stats.inputResponseCapHits == 0)
    }

    /// Only a completion that names the key closes its response before the tick render: not the
    /// key's own commit, not a userBlocking task that answers nothing (a person-caused flush), not
    /// a completion that ran before the key's own commit, and not one outside a userBlocking task.
    @Test func theResponseStaysOpenUntilTheTickRenderForWorkThatDoesNotAnswerTheKey() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let reply = budget.board.owner("action.reply")
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        let key = Self.frameExpectingKey(budget)
        // A completion in the key's own turn, before its commit: that commit carries it.
        budget.run(.userBlocking, owner: reply) { if let key { budget.noteAnswered(key) } }
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "a completion before the key's own commit closed the response at that commit")
        budget.run(.userBlocking, owner: reply) { clock.advance(ms: 1) }
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "a userBlocking task that answers nothing closed the response")
        budget.run(.visible, owner: budget.board.owner("sidebar.rows")) { if let key { budget.noteAnswered(key) } }
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "a visible task answered the person's key")
        #expect(!budget.mayRun(.automation))
        clock.advance(ms: 17)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen, "the tick render after the key closes it")
    }

    /// A reply that answered the previous key does not close the response of the key after it, and
    /// a run outside a dispatch answers no key.
    @Test func aCompletionOfAnEarlierKeyDoesNotCloseTheNextKeysResponse() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let reply = budget.board.owner("action.reply")
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(budget.answerableInput == nil, "a run outside a dispatch answers no key")
        let first = Self.frameExpectingKey(budget)
        budget.noteRenderPass(nanos: 1_000_000)
        let second = Self.frameExpectingKey(budget)
        #expect(first != second)
        budget.noteRenderPass(nanos: 1_000_000)
        budget.run(.userBlocking, owner: reply) { if let first { budget.noteAnswered(first) } }
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "the first key's reply closed the second key's response")
        budget.run(.userBlocking, owner: reply) { if let second { budget.noteAnswered(second) } }
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen, "the second key's own reply did not close its response")
        // A completion marked before a new key does not close that key's response.
        let third = Self.frameExpectingKey(budget)
        budget.noteRenderPass(nanos: 1_000_000)
        budget.run(.userBlocking, owner: reply) { if let third { budget.noteAnswered(third) } }
        _ = Self.frameExpectingKey(budget)
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "the third key's reply closed the fourth key's response")
    }

    /// The finding of the 208 review: a person's change in a frame-expecting key's turn posts a
    /// userBlocking flush that runs on the next turn, before any link tick. Neither that flush nor
    /// the render pass after it is the key's frame: automation stays held until the tick render.
    @Test func aPersonFlushInTheKeysTurnDoesNotCloseTheResponseBeforeTheTickRender() {
        let clock = BudgetClock()
        var turns: [@MainActor () -> Void] = []
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read),
                                             performTurn: { turns.append($0) }) { _ in FakeFrameLink() }
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        let model = UserBlockingModel()
        var applied: [Int] = []
        let token = ServiceObservation(.visible, owner: "test.person", on: work) { model.count } apply: { applied.append($0) }
        work.budget.noteDiscreteDispatch(began: true)
        work.causes.withCause(.person) { model.count = 1 }
        work.budget.noteDiscreteInput(expectsFrame: true)
        work.budget.noteDiscreteDispatch(began: false)
        #expect(work.postedCount(.userBlocking) == 1, "the person's change posted its userBlocking flush")
        for turn in turns { turn() }
        #expect(applied == [0, 1], "the flush ran on the next turn")
        // A render pass off the link's tick: the key's own commit, or the flush's.
        work.budget.noteRenderPass(nanos: 1_000_000)
        #expect(work.budget.isInputResponseOpen, "the person's flush closed the response before the tick render")
        #expect(!work.budget.mayRun(.automation), "automation ran in the gap the response protects")
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        work.budget.noteRenderPass(nanos: 1_000_000)
        #expect(!work.budget.isInputResponseOpen, "the tick render closes it")
        #expect(work.budget.mayRun(.automation))
        keeper.deactivate()
        withExtendedLifetime(token) {}
    }

    /// One discrete key whose turn expects a frame: its dispatch, the input it reports, the end of
    /// the dispatch. Returns the input an action run in it answers.
    private static func frameExpectingKey(_ budget: MainFrameBudget) -> MainFrameBudget.InputToken? {
        budget.noteDiscreteDispatch(began: true)
        let key = budget.answerableInput
        budget.noteDiscreteInput(expectsFrame: true)
        budget.noteDiscreteDispatch(began: false)
        return key
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

@MainActor @Observable
private final class UserBlockingModel {
    var count = 0
}

@MainActor
private final class UserBlockingInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}
