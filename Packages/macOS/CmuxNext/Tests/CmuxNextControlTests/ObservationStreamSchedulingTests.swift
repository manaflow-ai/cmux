import CmuxNextCompat
import CmuxNextWakeups
import Observation
import Testing

/// G1 of plans/cmux-next/main-thread-scheduling.md: every `ObservationStream` evaluation is a task of the main-thread
/// scheduler. While it runs, `MainTaskBoard` names the stream's site (`#fileID:#line`) as the owner, class visible, so
/// a stall record names it; its time is charged to the frame's visible share. Red before the stream ran its evaluations
/// through the scheduler: the board showed no task during an evaluation.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ObservationStreamSchedulingTests {
    @Test func aReEvaluationRunsAsAVisibleTaskOwnedByItsSite() async {
        let clock = SchedulingClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in SchedulingFakeLink() }
        work.runsObservationEvaluations()
        defer { ObservationSite.evaluations = nil }
        // Only this stream's evaluations move the clock, so only they can run past the visible share.
        let overBudget = OverBudgetTasks()
        work.budget.board.setOverBudgetSink { task, nanos in overBudget.append(task.owner, nanos) }
        let model = SchedulingModel()
        let seen = SeenTasks(board: work.budget.board)
        let site = "\(#fileID):\(#line + 1)"
        let stream = ObservationStream { () -> Int in
            seen.record()
            clock.advance(ms: 3)
            return model.value
        }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        model.value = 1
        let second = await iterator.next()

        #expect(first == 0)
        #expect(second == 1)

        #expect(seen.tasks.count == 2, "the first value and one re-evaluation")
        for task in seen.tasks {
            #expect(task?.owner == site, "the board names the stream's site while its evaluation runs")
            #expect(task?.workClass == .visible)
        }
        #expect(work.budget.board.running == nil, "the task ends with the evaluation")
        // Other suites' streams may evaluate on this runner meanwhile: they take no clock time.
        #expect(work.budget.stats.tasks[0] >= 2, "each evaluation is one visible task")
        #expect(work.budget.stats.maxTaskNanos[0] == 3_000_000, "its time is charged to the visible class")
        #expect(overBudget.tasks.count == 2, "a 3 ms evaluation runs past the 2.5 ms visible share")
        #expect(overBudget.tasks.allSatisfy { $0.owner == site && $0.nanos == 3_000_000 })
    }

    @Test func thePrimedFirstValueRunsAsAVisibleTaskOwnedByItsSite() async {
        let work = MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in SchedulingFakeLink() }
        work.runsObservationEvaluations()
        defer { ObservationSite.evaluations = nil }
        let model = SchedulingModel()
        let seen = SeenTasks(board: work.budget.board)
        let site = "\(#fileID):\(#line + 1)"
        let (value, later) = ObservationStream<Int>.current { () -> Int in
            seen.record()
            return model.value
        }
        #expect(value == 0)
        var iterator = later.makeAsyncIterator()
        model.value = 2
        let next = await iterator.next()
        #expect(next == 2)

        #expect(seen.tasks.count == 2)
        #expect(seen.tasks.allSatisfy { $0?.owner == site && $0?.workClass == .visible })
    }

    @Test func withNoRunnerAnEvaluationRunsUnscheduled() async {
        let work = MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in SchedulingFakeLink() }
        work.runsObservationEvaluations()
        ObservationSite.evaluations = nil
        let seen = SeenTasks(board: work.budget.board)
        let model = SchedulingModel()
        var iterator = ObservationStream { () -> Int in
            seen.record()
            return model.value
        }.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == 0)
        #expect(seen.tasks == [nil], "a removed runner schedules nothing")
        #expect(work.budget.stats.tasks[0] == 0)
    }

    @Test func anEvaluationOnAnIdleAppStartsAFreshWindow() async {
        let clock = SchedulingClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in SchedulingFakeLink() }
        work.runsObservationEvaluations()
        defer { ObservationSite.evaluations = nil }
        let model = SchedulingModel()
        var iterator = ObservationStream { () -> Int in
            clock.advance(ms: 3)
            return model.value
        }.makeAsyncIterator()
        _ = await iterator.next()
        // No display link runs: the next change comes a few frames later.
        clock.advance(ms: 20)
        model.value = 1
        _ = await iterator.next()
        clock.advance(ms: 20)
        #expect(work.budget.mayRun(.visible))
        #expect(work.budget.stats.maxFrameNanos[0] == 3_000_000,
                "two evaluations 20 ms apart are two frames' work, not one frame of 6 ms")
    }
}

@MainActor @Observable private final class SchedulingModel {
    var value = 0
}

/// What the board showed at each evaluation.
@MainActor private final class SeenTasks {
    private let board: MainTaskBoard
    private(set) var tasks: [MainTaskBoard.Task?] = []

    init(board: MainTaskBoard) {
        self.board = board
    }

    func record() { tasks.append(board.running) }
}

/// The tasks the board reported over budget (its sink runs on the main thread).
private final class OverBudgetTasks: Sendable {
    private let state = Mutex<[(owner: String, nanos: UInt64)]>([])
    var tasks: [(owner: String, nanos: UInt64)] { state.withLock { $0 } }
    func append(_ owner: String, _ nanos: UInt64) { state.withLock { $0.append((owner, nanos)) } }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor private final class SchedulingClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor private final class SchedulingFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
