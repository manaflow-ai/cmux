@testable import CmuxNextControl
import CmuxNextSettings
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
        let rig = StarvationRig()
        let budget = rig.budget
        // A long turn that ended before the link's last tick is not this period's cause.
        rig.turns.run("before", ms: 300)
        rig.spring.activate()
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.automation))
        rig.clock.advance(ms: 1)
        rig.turns.run("job", ms: 200)
        for workClass in MainWorkClass.budgeted { #expect(!budget.mayRun(workClass), "\(workClass) waits for the late frame") }
        #expect(budget.mayRun(.frame), "frame work never waits")
        #expect(budget.mayRun(.input), "input never waits")
        #expect(budget.isRenderStarved)
        #expect(rig.starvation.stats.events == 1, "one late period reports once")
        #expect(rig.starvation.stats.heldTasks == [1, 1, 1, 1])
        #expect(rig.starvation.last?.turn?.label == "job")
        #expect(rig.starvation.last?.link == rig.window.name)
        #expect(rig.visibility.asks == 1, "visibility is asked once per late period")
        #expect(rig.starvation.last?.message.contains("turn=job") == true)
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        #expect(!budget.isRenderStarved, "the link's next tick ends the hold")
        #expect(budget.mayRun(.automation))
        #expect(rig.starvation.stats.events == 1, "the late tick does not report the period again")
        rig.spring.deactivate()
    }

    /// The link's tick is a callout inside a run loop turn, and the job that kept the next tick from
    /// running came later in that same turn: the report names that turn, though it started before
    /// the tick.
    @Test func theJobInTheLateTicksOwnTurnIsNamed() {
        let rig = StarvationRig()
        rig.spring.activate()
        let turnStart = rig.clock.read()
        rig.clock.advance(ms: 1)
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 200)
        rig.turns.record("job in the tick's turn", startNanos: turnStart, endNanos: rig.clock.read())
        rig.turns.run("short", ms: 2)
        #expect(!rig.budget.mayRun(.visible))
        #expect(rig.starvation.last?.turn?.label == "job in the tick's turn")
        rig.spring.deactivate()
    }

    /// A late period with no budgeted work waiting still reports, once, at the late link's tick:
    /// the stall deadline ticks a link at the threshold, so every period ends in a tick.
    @Test func aLatePeriodWithNoWorkWaitingReportsAtTheLateTick() {
        let rig = StarvationRig()
        rig.spring.activate()
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 1)
        rig.turns.run("job", ms: 200)
        #expect(rig.starvation.stats.events == 0, "nothing asked yet")
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        #expect(rig.starvation.stats.events == 1)
        #expect(rig.starvation.last?.turn?.label == "job")
        rig.clock.advance(ms: 16)
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        #expect(rig.starvation.stats.events == 1, "frames on time report nothing")
        #expect(rig.budget.mayRun(.automation))
        rig.spring.deactivate()
    }

    /// The budgeted scheduler's own batch, and work posted on it (the deadlines MainDeadline runs
    /// through post), wait on the late window link: the budget tick that comes first runs none of
    /// it, the one after the window's tick runs it.
    @Test func aBudgetedBatchAndPostedWorkWaitForTheLateWindowsNextTick() {
        let rig = StarvationRig()
        let work = MainWorkScheduler.testing(budget: rig.budget) { _ in FakeFrameLink() }
        let queue = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: work)
        rig.spring.activate()
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        var ran: [String] = []
        queue.enqueue { ran.append("batch") }
        work.post(.automation, owner: "deadline") { ran.append("posted") }
        rig.clock.advance(ms: 200)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran.isEmpty, "the late window's frame goes first")
        #expect(queue.count == 1)
        #expect(work.postedCount(.automation) == 1)
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 1)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran.sorted() == ["batch", "posted"])
        #expect(rig.starvation.stats.events == 1)
        rig.spring.deactivate()
    }

    /// An occluded window (or one on a sleeping display) draws nothing a person waits for: its
    /// late link with active clients never holds automation and reports nothing, and later checks
    /// of the same period do not ask AppKit again.
    @Test func anOccludedWindowWithActiveClientsDoesNotStopAutomation() {
        let rig = StarvationRig(visibility: FakeRenderVisibility(shows: false))
        rig.spring.activate()
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 250)
        #expect(rig.budget.mayRun(.automation))
        // Past the next scan: the second check reads the link again and finds the period it saw.
        rig.clock.advance(ms: 150)
        #expect(rig.budget.mayRun(.automation))
        #expect(!rig.budget.isRenderStarved)
        #expect(rig.starvation.stats.events == 0)
        #expect(rig.visibility.asks == 1, "asked once for the period, not per check")
        rig.spring.deactivate()
    }

    /// A screen-hosted scheduler (the app's, the budgeted one) serves every window: while every
    /// window of the app is occluded its late frames hold nothing; once one shows, a late period
    /// holds work again.
    @Test func aScreenHostLinkHoldsNothingWhileEveryWindowIsOccluded() {
        let windows = FakeRenderVisibility(screenHostWindows: [false, false])
        let rig = StarvationRig(visibility: windows)
        rig.spring.activate()
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 200)
        #expect(rig.budget.mayRun(.automation), "every window is occluded")
        #expect(rig.starvation.stats.events == 0)
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        windows.screenHostWindows = [false, true]
        rig.clock.advance(ms: 200)
        #expect(!rig.budget.mayRun(.automation), "one window shows")
        #expect(rig.starvation.stats.events == 1)
        rig.spring.deactivate()
    }

    /// Only frame clients make a late link a late frame: a link with no active client holds
    /// nothing. With the feature off the guard only reports.
    @Test func noFrameClientMeansNoStarvationAndReportOnlyHoldsNothing() {
        let rig = StarvationRig(holdsWork: false, namesTurns: false)
        rig.clock.advance(ms: 500)
        #expect(rig.budget.mayRun(.visible))
        #expect(rig.starvation.stats.events == 0, "no active frame client: nothing is late")
        rig.spring.activate()
        rig.clock.advance(ms: 150)
        #expect(rig.budget.mayRun(.visible), "report-only: the late frame holds nothing")
        #expect(!rig.budget.isRenderStarved)
        #expect(rig.starvation.stats.events == 1)
        #expect(rig.starvation.last?.turn == nil)
        #expect(rig.starvation.last?.message.hasSuffix("turn=unattributed") == true)
        rig.spring.deactivate()
    }

    /// `debug.main_budget` shows the guard's counters.
    @Test func theBudgetReportShowsTheStarvationCounters() {
        let rig = StarvationRig()
        rig.spring.activate()
        rig.window.frameDidFire(timestamp: rig.clock.media(), refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 200)
        #expect(!rig.budget.mayRun(.visible))
        let report = rig.budget.report["render_starvation"]
        #expect(report?["holds_work"]?.boolValue == true)
        #expect(report?["events"]?.intValue == 1)
        #expect(report?["held_tasks"]?["visible"]?.intValue == 1)
        #expect((report?["max_gap_ms"]?.doubleValue ?? 0) > 199.9)
        #expect(MainFrameBudget().report["render_starvation"] == nil, "no guard, no part")
        rig.spring.deactivate()
    }

    /// A shown window whose link stops (its screen went away, a window the system still reports
    /// visible) ticks its spring on the stall deadline, 100 ms after the last tick plus the timer's
    /// hop: that is a FrameStall, not the main thread starving the frame. No check between the
    /// threshold and the stall tick, and none while the stall deadline paces it, reports or holds.
    @Test func aLinkThatStopsIsNotStarvation() async throws {
        let media = MediaTime()
        let clock = StallClock()
        let window = FrameScheduler.testing(clock: clock, mediaTime: media.read) { _ in FakeFrameLink() }
        let starvation = RenderStarvationGuard(holdsWork: true, visibility: FakeRenderVisibility(shows: true), mediaTime: media.read)
        starvation.watch(window)
        let budget = MainFrameBudget(starvation: starvation)
        var ticks = 0
        let spring = FrameClient(owner: "spring", on: window) { _ in ticks += 1; return true }
        spring.activate()
        try await clock.waitForSleeper()
        for cycle in 0..<5 {
            // The first stall tick is due at the threshold; later ones come from the stall deadline.
            media.advance(seconds: cycle == 0 ? 0.101 : 0.15)
            #expect(budget.mayRun(.automation), "cycle \(cycle): a check before the stall tick")
            let before = ticks
            media.advance(seconds: 0.002)
            clock.advance(by: .milliseconds(100))
            try await clock.waitForSleeper()
            #expect(ticks == before + 1, "cycle \(cycle): the stall deadline ticked the spring")
            #expect(window.ticksOffLink)
            #expect(budget.mayRun(.automation), "cycle \(cycle): a check after the stall tick")
        }
        #expect(starvation.stats.events == 0)
        #expect(starvation.stats.heldTasks == [0, 0, 0, 0])
        spring.deactivate()
    }

    /// The stall deadline is the guard's check timer: when the main thread holds the link's next
    /// tick past the threshold, the stall tick that finally runs reports the period, once, with no
    /// budgeted work waiting.
    @Test func aStallTickTheMainThreadHeldReportsOnce() async throws {
        let media = MediaTime()
        let clock = StallClock()
        let window = FrameScheduler.testing(clock: clock, mediaTime: media.read) { _ in FakeFrameLink() }
        let starvation = RenderStarvationGuard(holdsWork: true, visibility: FakeRenderVisibility(shows: true), mediaTime: media.read)
        starvation.watch(window)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        spring.activate()
        try await clock.waitForSleeper()
        // A 300 ms main-thread job: the stall deadline's hop runs only after it.
        media.advance(seconds: 0.3)
        clock.advance(by: .milliseconds(100))
        try await clock.waitForSleeper()
        #expect(starvation.stats.events == 1)
        #expect(abs(starvation.stats.maxGap - 0.3) < 1e-6)
        // The link stays stopped: the stall deadline paces it from here, which is no starvation.
        for _ in 0..<3 {
            media.advance(seconds: 0.102)
            clock.advance(by: .milliseconds(100))
            try await clock.waitForSleeper()
        }
        #expect(starvation.stats.events == 1)
        spring.deactivate()
    }
}

/// A window link on the budget's clock, a spring on it, and a guard that watches it.
@MainActor
struct StarvationRig {
    let clock = BudgetClock()
    let turns: FakeTurnMeter
    let visibility: FakeRenderVisibility
    let window: FrameScheduler
    let starvation: RenderStarvationGuard
    let budget: MainFrameBudget
    let spring: FrameClient

    init(holdsWork: Bool = true, visibility: FakeRenderVisibility = FakeRenderVisibility(shows: true), namesTurns: Bool = true) {
        self.turns = FakeTurnMeter(clock: clock)
        self.visibility = visibility
        window = FrameScheduler.testing(mediaTime: clock.media) { _ in FakeFrameLink() }
        starvation = RenderStarvationGuard(holdsWork: holdsWork, visibility: visibility, turns: namesTurns ? self.turns : nil,
                                           mediaTime: clock.media)
        starvation.watch(window)
        budget = MainFrameBudget(starvation: starvation, uptimeNanos: clock.read)
        spring = FrameClient(owner: "spring", on: window) { _ in true }
    }
}

/// A turn meter the test feeds: each `run` is one main-thread turn of unattributed time.
@MainActor
final class FakeTurnMeter: UnattributedTurnSource {
    private let clock: BudgetClock
    private var turns: [UnattributedTurn] = []
    init(clock: BudgetClock) { self.clock = clock }

    func run(_ label: String, ms: Double) {
        let start = clock.read()
        clock.advance(ms: ms)
        record(label, startNanos: start, endNanos: clock.read())
    }

    func record(_ label: String, startNanos: UInt64, endNanos: UInt64) {
        let nanos = endNanos - startNanos
        turns.append(UnattributedTurn(label: label, startNanos: startNanos, durationNanos: nanos, unattributedNanos: nanos))
    }

    func topUnattributedTurn(endingAfter sinceNanos: UInt64) -> UnattributedTurn? {
        turns.filter { $0.startNanos + $0.durationNanos > sinceNanos }.max { $0.unattributedNanos < $1.unattributedNanos }
    }
}

/// Whether a scheduler's frames show, set by the test; counts the questions. With
/// `screenHostWindows`, a screen-hosted scheduler's frames show while any of those windows shows,
/// as ``AppKitRenderVisibility`` rules.
@MainActor
final class FakeRenderVisibility: RenderVisibility {
    var shows: Bool
    var screenHostWindows: [Bool]?
    private(set) var asks = 0
    init(shows: Bool) { self.shows = shows }
    init(screenHostWindows: [Bool]) {
        shows = false
        self.screenHostWindows = screenHostWindows
    }

    func showsFrames(of scheduler: FrameScheduler) -> Bool {
        asks += 1
        if scheduler.window == nil, let screenHostWindows { return screenHostWindows.contains(true) }
        return shows
    }
}
