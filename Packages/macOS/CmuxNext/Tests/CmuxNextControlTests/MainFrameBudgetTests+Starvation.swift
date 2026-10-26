import CmuxNextWakeups
import Foundation
import Testing

/// The rendering starvation guard (Chrome's `kRenderingStarved`,
/// plans/cmux-next/chrome-parity/p06-scheduler.md task 004): a shown window's late frame holds the
/// budgeted classes until its link ticks again, and the late period reports the turn to blame.
extension MainFrameBudgetTests {
    /// A main-thread job nobody posted keeps a shown window's spring from ticking for 200 ms (12
    /// frames at 60 Hz): the budget holds every budgeted class until that link ticks again, never
    /// input or frame work, and the late period reports once, naming the job's turn.
    @Test func aLateShownFrameHoldsBudgetedWorkUntilItsNextTickAndReportsTheJobOnce() {
        let clock = BudgetClock()
        let turns = FakeTurnMeter(clock: clock)
        let visibility = FakeRenderVisibility(shows: true)
        let window = FrameScheduler.testing(mediaTime: clock.media) { _ in FakeFrameLink() }
        let starvation = RenderStarvationGuard(holdsWork: true, links: { [window] }, visibility: visibility, turns: turns,
                                               mediaTime: clock.media)
        let budget = MainFrameBudget(starvation: starvation, uptimeNanos: clock.read)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        // A long turn before the link's last tick is not this period's cause.
        turns.run("before", ms: 300)
        spring.activate()
        window.frameDidFire(timestamp: clock.media(), refreshInterval: 1.0 / 60)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.automation))
        clock.advance(ms: 1)
        turns.run("job", ms: 200)
        for workClass in MainWorkClass.budgeted { #expect(!budget.mayRun(workClass), "\(workClass) waits for the late frame") }
        #expect(budget.mayRun(.frame), "frame work never waits")
        #expect(budget.mayRun(.input), "input never waits")
        #expect(budget.isRenderStarved)
        #expect(starvation.stats.events == 1, "one late period reports once")
        #expect(starvation.stats.heldTasks == [1, 1, 1])
        #expect(starvation.last?.turn?.label == "job")
        #expect(starvation.last?.link == window.name)
        #expect(visibility.asks == 1, "visibility is asked once per late period")
        #expect(starvation.last?.message.contains("turn=job") == true)
        window.frameDidFire(timestamp: clock.media(), refreshInterval: 1.0 / 60)
        #expect(!budget.isRenderStarved, "the link's next tick ends the hold")
        #expect(budget.mayRun(.automation))
        #expect(starvation.stats.events == 1)
        spring.deactivate()
    }

    /// The budgeted scheduler's own batch waits on the late window link: the budget tick that comes
    /// first runs none of it, the one after the window's tick runs it.
    @Test func aBudgetedBatchWaitsForTheLateWindowsNextTick() {
        let clock = BudgetClock()
        let window = FrameScheduler.testing(mediaTime: clock.media) { _ in FakeFrameLink() }
        let starvation = RenderStarvationGuard(holdsWork: true, links: { [window] }, visibility: FakeRenderVisibility(shows: true),
                                               mediaTime: clock.media)
        let budget = MainFrameBudget(starvation: starvation, uptimeNanos: clock.read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let queue = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: work)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        spring.activate()
        window.frameDidFire(timestamp: clock.media(), refreshInterval: 1.0 / 60)
        var ran = 0
        queue.enqueue { ran += 1 }
        clock.advance(ms: 200)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran == 0, "the late window's frame goes first")
        #expect(queue.count == 1)
        window.frameDidFire(timestamp: clock.media(), refreshInterval: 1.0 / 60)
        clock.advance(ms: 1)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran == 1)
        #expect(starvation.stats.events == 1)
        spring.deactivate()
    }

    /// An occluded window (or one on a sleeping display) draws nothing a person waits for: its
    /// late link with active clients never holds automation and reports nothing.
    @Test func anOccludedWindowWithActiveClientsDoesNotStopAutomation() {
        let clock = BudgetClock()
        let visibility = FakeRenderVisibility(shows: false)
        let window = FrameScheduler.testing(mediaTime: clock.media) { _ in FakeFrameLink() }
        let starvation = RenderStarvationGuard(holdsWork: true, links: { [window] }, visibility: visibility, mediaTime: clock.media)
        let budget = MainFrameBudget(starvation: starvation, uptimeNanos: clock.read)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        spring.activate()
        window.frameDidFire(timestamp: clock.media(), refreshInterval: 1.0 / 60)
        clock.advance(ms: 250)
        #expect(budget.mayRun(.automation))
        #expect(budget.mayRun(.automation))
        #expect(!budget.isRenderStarved)
        #expect(starvation.stats.events == 0)
        #expect(visibility.asks == 1, "asked once for the period, not per task")
        spring.deactivate()
    }

    /// Only frame clients make a late link a late frame: a link with no active client holds
    /// nothing. With the feature off the guard only reports.
    @Test func noFrameClientMeansNoStarvationAndReportOnlyHoldsNothing() {
        let clock = BudgetClock()
        let window = FrameScheduler.testing(mediaTime: clock.media) { _ in FakeFrameLink() }
        let reporting = RenderStarvationGuard(holdsWork: false, links: { [window] }, visibility: FakeRenderVisibility(shows: true),
                                              mediaTime: clock.media)
        let budget = MainFrameBudget(starvation: reporting, uptimeNanos: clock.read)
        clock.advance(ms: 500)
        #expect(budget.mayRun(.visible))
        #expect(reporting.stats.events == 0, "no active frame client: nothing is late")
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        spring.activate()
        clock.advance(ms: 150)
        #expect(budget.mayRun(.visible), "report-only: the late frame holds nothing")
        #expect(!budget.isRenderStarved)
        #expect(reporting.stats.events == 1)
        #expect(reporting.last?.turn == nil)
        #expect(reporting.last?.message.hasSuffix("turn=unattributed") == true)
        spring.deactivate()
    }
}

/// A turn meter the test feeds: each `run` is one main-thread turn of unattributed time.
@MainActor
private final class FakeTurnMeter: UnattributedTurnSource {
    private let clock: BudgetClock
    private var turns: [UnattributedTurn] = []
    init(clock: BudgetClock) { self.clock = clock }

    func run(_ label: String, ms: Double) {
        let start = clock.read()
        clock.advance(ms: ms)
        let nanos = clock.read() - start
        turns.append(UnattributedTurn(label: label, startNanos: start, durationNanos: nanos, unattributedNanos: nanos))
    }

    func topUnattributedTurn(since sinceNanos: UInt64) -> UnattributedTurn? {
        turns.filter { $0.startNanos >= sinceNanos }.max { $0.unattributedNanos < $1.unattributedNanos }
    }
}

/// Whether a scheduler's frames show, fixed by the test; counts the questions.
@MainActor
private final class FakeRenderVisibility: RenderVisibility {
    let shows: Bool
    private(set) var asks = 0
    init(shows: Bool) { self.shows = shows }

    func showsFrames(of scheduler: FrameScheduler) -> Bool {
        asks += 1
        return shows
    }
}
