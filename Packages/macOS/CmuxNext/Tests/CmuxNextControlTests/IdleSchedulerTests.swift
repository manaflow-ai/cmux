import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The idle class (plans/cmux-next/chrome-parity/p06-scheduler.md, task 005): Chrome's idle periods
/// (`third_party/blink/renderer/platform/scheduler/common/idle_helper.h`) on the main-thread
/// scheduler, driven by a fake clock, a fake period timer and hand-fired frames.
@MainActor @Suite(.timeLimit(.minutes(1))) struct IdleSchedulerTests {
    /// A long period starts after 50 ms of quiet and ends at most 50 ms later.
    @Test func aLongPeriodStartsAfter50MsOfQuietWithADeadlineOfAtMost50Ms() {
        let rig = IdleRig()
        var remaining: [Duration] = []
        rig.work.postIdle(owner: "test.idle") { deadline in remaining.append(deadline.timeRemaining) }
        #expect(remaining.isEmpty, "an idle post never runs inline")
        rig.timer.run(ms: 49)
        #expect(remaining.isEmpty, "the quiet before a long period is 50 ms")
        rig.timer.run(ms: 2)
        #expect(remaining == [.milliseconds(50)])
        #expect(rig.work.idle.stats.longPeriods == 1)
        #expect(rig.work.idle.count == 0)
    }

    /// While the launch has not settled no idle period starts and no timer is armed; at the settle,
    /// with the quiet long past, the period comes on the next timer fire (idle
    /// work is held until the settle).
    @Test func noIdlePeriodBeforeTheLaunchSettles() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let rig = IdleRig(startup: startup)
        var ran = 0
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.timer.run(ms: 500)
        #expect(ran == 0, "an idle period ran while launching")
        #expect(rig.timer.fireAt == nil, "the idle timer was armed while launching")
        startup.noteFirstFrame()
        #expect(startup.phase == .revealed)
        rig.timer.run(ms: 500)
        #expect(ran == 0, "an idle period ran after the reveal, before the settle")
        startup.markDone(.firstSnapshot)
        startup.markDone(.restoreDone)
        startup.markDone(.visiblePageIdle)
        #expect(startup.phase == .settled)
        #expect(rig.timer.fireAt != nil, "the settle armed no idle period")
        rig.timer.run(ms: 1)
        #expect(ran == 1)
    }

    /// The next main-thread deadline ends a long period early (min(50 ms, next fire)).
    @Test func aLongPeriodEndsBeforeTheNextMainDeadline() {
        let rig = IdleRig()
        let deadlines = FakeDeadlines()
        rig.work.idle.deadlines = deadlines
        deadlines.nextFireNanos = rig.clock.now + 70_000_000
        var remaining: Duration?
        rig.work.postIdle(owner: "test.idle") { deadline in remaining = deadline.timeRemaining }
        rig.timer.run(ms: 51)
        #expect(remaining == .milliseconds(20))
    }

    /// The idle task runs as `idle` on the board, named with its owner and posting site.
    @Test func anIdleTaskRunsOnTheBoardAsIdleWithItsPostingSite() {
        let rig = IdleRig()
        var seen: MainTaskBoard.Task?
        let line: UInt = #line + 1
        rig.work.postIdle(owner: "test.board") { _ in seen = rig.work.board.running }
        rig.timer.run(ms: 51)
        #expect(seen?.workClass == .idle)
        #expect(seen?.owner == "test.board")
        #expect(seen?.postedFrom == MainTaskBoard.PostedFrom(file: "CmuxNextControlTests/IdleSchedulerTests.swift", line: line))
    }

    /// No idle period while a person's input is pending: one retry after the quiet, then no timer
    /// until the input's dispatch, and the period comes 50 ms of quiet after it.
    @Test func noIdleWhileInputIsPending() {
        let rig = IdleRig()
        var ran = 0
        rig.input.pending = true
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.timer.run(ms: 101)
        let fires = rig.timer.fires
        #expect(fires == 2, "the first try and one retry")
        rig.timer.run(ms: 500)
        #expect(ran == 0, "an idle task ran while a key was pending")
        #expect(rig.timer.fires == fires, "the idle timer polled while input stayed pending")
        #expect(rig.timer.fireAt == nil)
        rig.input.pending = false
        rig.work.idle.noteInput()
        rig.timer.run(ms: 49)
        #expect(ran == 0, "the quiet starts at the input's dispatch")
        rig.timer.run(ms: 2)
        #expect(ran == 1)
    }

    /// A dispatched input pushes the next long period out to 50 ms after it.
    @Test func noteInputRestartsTheQuiet() {
        let rig = IdleRig()
        var ran = 0
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.timer.run(ms: 30)
        rig.work.idle.noteInput()
        rig.timer.run(ms: 21)
        #expect(ran == 0, "a long period started 21 ms after a key")
        rig.timer.run(ms: 30)
        #expect(ran == 1)
    }

    /// Input that arrives during a period ends it at the next task; the rest waits for quiet.
    @Test func inputEndsThePeriod() {
        let rig = IdleRig()
        var ran: [String] = []
        rig.work.postIdle(owner: "test.first") { _ in
            ran.append("first")
            rig.clock.advance(ms: 1)
            rig.input.pending = true
        }
        rig.work.postIdle(owner: "test.second") { _ in ran.append("second") }
        rig.work.postIdle(owner: "test.third") { _ in ran.append("third") }
        rig.timer.run(ms: 51)
        #expect(ran == ["first"])
        #expect(rig.work.idle.stats.endedByInput == 1)
        rig.input.pending = false
        rig.timer.run(ms: 51)
        #expect(ran == ["first", "second", "third"])
    }

    /// While a frame client keeps the budgeted link running, no long period starts and no timer is
    /// armed; once it stops, the quiet starts.
    @Test func noLongIdleWhileAFrameClientIsActive() {
        let rig = IdleRig()
        let keeper = IdleLinkKeeper(on: rig.work)
        var ran = 0
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.timer.run(ms: 500)
        #expect(ran == 0, "a long idle period ran while frames were running")
        #expect(rig.timer.fireAt == nil, "the idle timer was armed while frames were running")
        keeper.stop()
        rig.timer.run(ms: 49)
        #expect(ran == 0, "the quiet starts when the frames stop")
        rig.timer.run(ms: 2)
        #expect(ran == 1)
    }

    /// A display link on another scheduler (a window animation) holds long periods too, with no
    /// timer armed; its end starts the quiet.
    @Test func noLongIdleWhileAnotherSchedulerHasAFrameClient() {
        let rig = IdleRig()
        var ran = 0
        rig.otherLinks.set(running: true)
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.timer.run(ms: 300)
        #expect(ran == 0)
        #expect(rig.timer.fires == 0, "the idle timer polled while another scheduler's link ran")
        #expect(rig.timer.fireAt == nil)
        rig.otherLinks.set(running: false)
        rig.timer.run(ms: 49)
        #expect(ran == 0, "the quiet starts when the other link stops")
        rig.timer.run(ms: 2)
        #expect(ran == 1)
    }

    /// Another scheduler's link frame opens a short period after its render pass.
    @Test func anotherSchedulersFrameOpensAShortPeriod() {
        let rig = IdleRig()
        rig.otherLinks.set(running: true)
        var deadlines: [UInt64] = []
        rig.work.postIdle(owner: "test.idle") { deadline in deadlines.append(deadline.deadlineNanos) }
        let timestamp = rig.clock.seconds
        rig.otherLinks.frame(timestamp: timestamp, refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 2)
        rig.work.renderPassEnded(nanos: 500_000)
        #expect(deadlines == [UInt64(max(0, timestamp + 1.0 / 60) * 1_000_000_000) - 1_000_000])
        #expect(rig.work.idle.stats.shortPeriods == 1)
        #expect(rig.timer.fires == 0)
    }

    /// Budgeted work an idle task posts runs before the next idle task (Chrome picks the higher
    /// queue between idle tasks): the period ends, and the rest waits for the quiet after it.
    @Test func aHigherClassPostEndsThePeriod() {
        let rig = IdleRig()
        var ran: [String] = []
        rig.work.postIdle(owner: "test.first") { _ in
            ran.append("first")
            rig.work.post(.visible, owner: "test.visible") { ran.append("visible") }
        }
        rig.work.postIdle(owner: "test.second") { _ in ran.append("second") }
        rig.timer.run(ms: 51)
        #expect(ran == ["first"], "an idle task ran ahead of visible work")
        #expect(rig.work.idle.stats.endedByHigherWork == 1)
        spinMainRunLoop(until: { ran.count == 2 })
        #expect(ran == ["first", "visible"])
        rig.timer.run(ms: 51)
        #expect(ran == ["first", "visible", "second"])
    }

    /// A display link an idle task starts (an animation) ends the long period.
    @Test func aLinkStartedInAnIdleTaskEndsTheLongPeriod() {
        let rig = IdleRig()
        var ran: [String] = []
        var keeper: IdleLinkKeeper?
        rig.work.postIdle(owner: "test.first") { _ in
            ran.append("first")
            keeper = IdleLinkKeeper(on: rig.work)
        }
        rig.work.postIdle(owner: "test.second") { _ in ran.append("second") }
        rig.timer.run(ms: 51)
        #expect(ran == ["first"], "the long period went on while a link ran")
        #expect(rig.timer.fireAt == nil)
        keeper?.stop()
        rig.timer.run(ms: 51)
        #expect(ran == ["first", "second"])
    }

    /// A short period runs after a link frame's render pass with 2 ms or more left before the next
    /// vsync, until 1 ms before it; not with less time left, and not while budgeted work is held.
    @Test func aShortPeriodRunsBetweenFramesUntilOneMillisecondBeforeVsync() {
        let rig = IdleRig()
        let keeper = IdleLinkKeeper(on: rig.work)
        var deadlines: [UInt64] = []
        rig.work.postIdle(owner: "test.idle") { deadline in deadlines.append(deadline.deadlineNanos) }

        // Less than 2 ms before the next vsync: no short period.
        var timestamp = rig.clock.seconds
        rig.work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        rig.clock.advance(ms: 15)
        rig.work.renderPassEnded(nanos: 500_000)
        #expect(deadlines.isEmpty, "a short period ran with under 2 ms left before vsync")

        // Budgeted work held for the next frame: no short period.
        rig.clock.advance(ms: 2)
        timestamp = rig.clock.seconds
        rig.work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        rig.work.post(.visible, owner: "test.visible") {}
        rig.clock.advance(ms: 2)
        rig.work.renderPassEnded(nanos: 500_000)
        #expect(deadlines.isEmpty, "a short period ran ahead of held budgeted work")

        rig.clock.advance(ms: 15)
        timestamp = rig.clock.seconds
        rig.work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        #expect(rig.work.postedCount(.visible) == 0)
        rig.clock.advance(ms: 2)
        rig.work.renderPassEnded(nanos: 500_000)
        let vsync = UInt64(max(0, timestamp + 1.0 / 60) * 1_000_000_000)
        #expect(deadlines == [vsync - 1_000_000])
        #expect(rig.work.idle.stats.shortPeriods == 1)
        #expect(rig.work.idle.stats.longPeriods == 0)

        // A render pass with no link frame before it (any other run loop pass) gives no period.
        rig.work.postIdle(owner: "test.idle") { deadline in deadlines.append(deadline.deadlineNanos) }
        rig.work.renderPassEnded(nanos: 500_000)
        #expect(deadlines.count == 1)
        keeper.stop()
    }

    /// A task posted from an idle task waits for the next period.
    @Test func aNestedPostWaitsForTheNextPeriod() {
        let rig = IdleRig()
        var ran: [String] = []
        rig.work.postIdle(owner: "test.outer") { _ in
            ran.append("outer")
            rig.work.postIdle(owner: "test.inner") { _ in ran.append("inner") }
        }
        rig.timer.run(ms: 51)
        #expect(ran == ["outer"], "a nested post ran in the period it was posted in")
        #expect(rig.work.idle.count == 1)
        rig.timer.run(ms: 50)
        #expect(ran == ["outer", "inner"])
        #expect(rig.work.idle.stats.longPeriods == 2)
    }

    /// Only a task posted with a `maxDelay` moves to background when idle time does not come;
    /// it runs there with `didTimeout`. Without one, it waits, and no timer is armed for it.
    @Test func promotionToBackgroundOnlyWithMaxDelay() {
        let rig = IdleRig()
        let keeper = IdleLinkKeeper(on: rig.work)
        var ran: [String: Bool] = [:]
        rig.work.postIdle(owner: "test.bounded", maxDelay: .milliseconds(100)) { deadline in ran["bounded"] = deadline.didTimeout }
        rig.work.postIdle(owner: "test.unbounded") { deadline in ran["unbounded"] = deadline.didTimeout }
        rig.timer.run(ms: 99)
        #expect(rig.work.idle.stats.promoted == 0)
        rig.timer.run(ms: 2)
        #expect(rig.work.idle.stats.promoted == 1)
        #expect(rig.work.postedCount(.background) == 1)
        rig.clock.advance(ms: 1)
        rig.work.frameDidFire(timestamp: rig.clock.seconds, refreshInterval: 1.0 / 60)
        #expect(ran == ["bounded": true])
        #expect(rig.timer.fireAt == nil, "a timer was armed for a task with no maxDelay while frames run")
        rig.timer.run(ms: 10_000)
        #expect(rig.work.idle.stats.promoted == 1)
        #expect(rig.work.idle.count == 1)
        keeper.stop()
        rig.timer.run(ms: 51)
        #expect(ran == ["bounded": true, "unbounded": false])
    }

    /// A task whose node is released before its `maxDelay` is dropped, never promoted.
    @Test func aReleasedNodesTaskIsDroppedAtItsMaxDelay() {
        let rig = IdleRig()
        let keeper = IdleLinkKeeper(on: rig.work)
        let window = VisibilityNode(root: "window", own: .visible, uptime: rig.clock.uptime)
        var tab: VisibilityNode? = VisibilityNode("tab", parent: window)
        var ran = false
        rig.work.postIdle(owner: "test.tab", maxDelay: .milliseconds(500), node: tab) { _ in ran = true }
        tab = nil
        rig.timer.run(ms: 501)
        #expect(rig.work.idle.stats.dropped == 1)
        #expect(rig.work.idle.stats.promoted == 0)
        #expect(rig.work.postedCount(.background) == 0)
        rig.work.frameDidFire(timestamp: rig.clock.seconds, refreshInterval: 1.0 / 60)
        #expect(!ran)
        #expect(rig.work.idle.trackedNodes == 0)
        keeper.stop()
    }

    /// A promoted task of a node that is not visible is held as the node's background queue holds
    /// it: posted when the node shows, or at a hidden wake.
    @Test func aPromotedTaskOfAHiddenNodeWaitsForShowOrAHiddenWake() {
        let rig = IdleRig()
        let keeper = IdleLinkKeeper(on: rig.work)
        let window = VisibilityNode(root: "window", own: .visible, uptime: rig.clock.uptime)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        var ran: [String: Bool] = [:]
        rig.work.postIdle(owner: "test.tab", maxDelay: .milliseconds(100), node: tab) { deadline in ran["tab"] = deadline.didTimeout }
        rig.timer.run(ms: 101)
        #expect(rig.work.idle.stats.promoted == 1)
        #expect(rig.work.postedCount(.background) == 0, "a hidden node's promoted task was posted unthrottled")
        tab.set(.visible)
        #expect(rig.work.postedCount(.background) == 1)
        rig.work.frameDidFire(timestamp: rig.clock.seconds, refreshInterval: 1.0 / 60)
        #expect(ran == ["tab": true])

        var wakes: [@MainActor () -> Void] = []
        rig.work.hiddenWake = { _, wake in wakes.append(wake) }
        let other = VisibilityNode("other", own: .hidden, parent: window)
        rig.work.postIdle(owner: "test.other", maxDelay: .milliseconds(100), node: other) { deadline in ran["other"] = deadline.didTimeout }
        rig.timer.run(ms: 101)
        #expect(wakes.count == 1)
        #expect(rig.work.postedCount(.background) == 0)
        wakes.removeFirst()()
        rig.work.frameDidFire(timestamp: rig.clock.seconds, refreshInterval: 1.0 / 60)
        #expect(ran == ["tab": true, "other": true])
        keeper.stop()
    }

    /// The tasks of one node share one record (one subscription), released when they ran.
    @Test func aNodesTasksShareOneRecord() {
        let rig = IdleRig()
        let window = VisibilityNode(root: "window", own: .visible, uptime: rig.clock.uptime)
        let tab = VisibilityNode("tab", parent: window)
        var ran = 0
        for _ in 0..<100 {
            rig.work.postIdle(owner: "test.tab", node: tab) { _ in ran += 1 }
        }
        #expect(rig.work.idle.trackedNodes == 1)
        tab.set(.hidden)
        tab.set(.visible)
        rig.timer.run(ms: 51)
        #expect(ran == 100)
        #expect(rig.work.idle.trackedNodes == 0)
        #expect(rig.work.idle.count == 0)
    }

    /// Occluded is not hidden: an occluded app or node keeps its idle periods past 10 s.
    @Test func anOccludedNodeKeepsIdlePeriodsPastTenSeconds() {
        let rig = IdleRig()
        let app = VisibilityNode(root: "app", own: .visible, uptime: rig.clock.uptime)
        rig.work.idle.setAppNode(app)
        let tab = VisibilityNode("tab", own: .occluded, parent: app)
        app.set(.occluded)
        rig.timer.run(ms: 11_000)
        #expect(app.hiddenStateSince == nil)
        var ran = 0
        rig.work.postIdle(owner: "test.tab", node: tab) { _ in ran += 1 }
        rig.timer.run(ms: 51)
        #expect(ran == 1, "idle stopped 10 s after an occlusion")
    }

    /// An overdue next deadline holds long periods with no timer re-poll; the registry's change
    /// call lets the next one start.
    @Test func anOverdueDeadlineArmsNoTimerUntilTheRegistryReportsAChange() {
        let rig = IdleRig()
        let deadlines = FakeDeadlines()
        deadlines.nextFireNanos = rig.clock.now - 1_000_000
        rig.work.idle.deadlines = deadlines
        var ran = 0
        rig.work.postIdle(owner: "test.idle") { _ in ran += 1 }
        rig.timer.run(ms: 1_000)
        #expect(ran == 0)
        #expect(rig.timer.fires == 1, "the idle timer re-polled an overdue deadline")
        #expect(rig.timer.fireAt == nil)
        deadlines.nextFireNanos = nil
        deadlines.onNextFireChange?()
        rig.timer.run(ms: 1)
        #expect(ran == 1)
    }

    /// Idle periods stop 10 s after the app node goes hidden (no timer armed, no wakeups) and
    /// resume when it shows.
    @Test func noIdleTenSecondsAfterTheAppIsHidden() {
        let rig = IdleRig()
        let app = VisibilityNode(root: "app", own: .visible, uptime: rig.clock.uptime)
        rig.work.idle.setAppNode(app)
        var ran: [String] = []
        app.set(.hidden)
        rig.work.postIdle(owner: "test.soon") { _ in ran.append("soon") }
        rig.timer.run(ms: 51)
        #expect(ran == ["soon"], "idle stops 10 s after the hide, not at once")

        rig.timer.run(ms: 10_000)
        rig.work.postIdle(owner: "test.late") { _ in ran.append("late") }
        let fires = rig.timer.fires
        rig.timer.run(ms: 60_000)
        #expect(ran == ["soon"], "an idle task ran more than 10 s after the app was hidden")
        #expect(rig.timer.fires == fires, "the idle timer woke while the app was hidden")
        #expect(rig.timer.fireAt == nil)

        app.set(.visible)
        rig.timer.run(ms: 51)
        #expect(ran == ["soon", "late"])
    }

    /// A task's own node hidden for 10 s holds only that task; showing the node resumes it, and
    /// releasing the node drops it.
    @Test func aTaskStopsTenSecondsAfterItsNodeIsHiddenAndResumesOnShow() {
        let rig = IdleRig()
        let window = VisibilityNode(root: "window", own: .visible, uptime: rig.clock.uptime)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        var released: VisibilityNode? = VisibilityNode("released", own: .hidden, parent: window)
        rig.timer.run(ms: 10_000)
        var ran: [String] = []
        rig.work.postIdle(owner: "test.tab", node: tab) { _ in ran.append("tab") }
        rig.work.postIdle(owner: "test.released", node: released) { _ in ran.append("released") }
        rig.work.postIdle(owner: "test.free") { _ in ran.append("free") }
        rig.timer.run(ms: 51)
        #expect(ran == ["free"])
        #expect(rig.work.idle.count == 2)
        let fires = rig.timer.fires
        rig.timer.run(ms: 5_000)
        #expect(rig.timer.fires == fires, "the idle timer woke for tasks whose nodes are hidden")

        released = nil
        tab.set(.visible)
        rig.timer.run(ms: 51)
        #expect(ran == ["free", "tab"])
        #expect(rig.work.idle.stats.dropped == 1)
        #expect(rig.work.idle.count == 0)
    }

    /// An empty idle queue arms no timer and records no wakeup, through frames coming and going;
    /// a drained queue disarms it again.
    @Test func zeroWakeupsOverTenSecondsWhenTheQueueIsEmpty() {
        let rig = IdleRig()
        rig.timer.run(ms: 10_000)
        let keeper = IdleLinkKeeper(on: rig.work)
        rig.work.frameDidFire(timestamp: rig.clock.seconds, refreshInterval: 1.0 / 60)
        rig.work.renderPassEnded(nanos: 500_000)
        keeper.stop()
        rig.timer.run(ms: 10_000)
        #expect(rig.timer.arms == 0)
        #expect(rig.idleWakeups == 0)

        rig.work.postIdle(owner: "test.idle") { _ in }
        rig.timer.run(ms: 51)
        rig.timer.run(ms: 10_000)
        #expect(rig.timer.fires == 1)
        #expect(rig.idleWakeups == 1)
        #expect(rig.timer.fireAt == nil)
    }
}

// MARK: Fixtures

/// A scheduler on a fake link, with a fake clock, input source and idle timer.
@MainActor
private final class IdleRig {
    let clock: IdleClock
    let input: IdleFakeInput
    let otherLinks: FakeOtherLinks
    let timer: FakeIdleTimer
    let ledger: WakeupLedger
    let work: MainWorkScheduler

    init(startup: StartupPhase = .settled()) {
        let clock = IdleClock(), input = IdleFakeInput(), otherLinks = FakeOtherLinks(), ledger = WakeupLedger()
        let timer = FakeIdleTimer(clock: clock)
        self.clock = clock
        self.input = input
        self.otherLinks = otherLinks
        self.ledger = ledger
        self.timer = timer
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read), ledger: ledger,
                                         startup: startup, idleTimer: timer, otherLinks: otherLinks) { _ in IdleFakeLink() }
    }

    /// Idle period timer fires recorded in the wakeup ledger.
    var idleWakeups: UInt64 {
        ledger.snapshot().filter { $0.owner == "IdleScheduler" }.reduce(0) { $0 + $1.count }
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class IdleClock {
    var now: UInt64 = 10_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    var uptime: VisibilityNode.Uptime { { [self] in .nanoseconds(Int64(self.now)) } }
    /// Now in seconds (the display link's timestamp base).
    var seconds: Double { Double(now) / 1_000_000_000 }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

/// The idle period timer, fired by moving the clock.
@MainActor
private final class FakeIdleTimer: IdlePeriodTimer {
    private let clock: IdleClock
    private var fire: (@MainActor () -> Void)?
    /// When the armed fire is due; nil while disarmed.
    private(set) var fireAt: UInt64?
    private(set) var arms = 0
    private(set) var fires = 0

    init(clock: IdleClock) { self.clock = clock }

    func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void) {
        arms += 1
        fireAt = clock.now + delay
        self.fire = fire
    }

    func cancel() {
        fireAt = nil
        fire = nil
    }

    /// Moves the clock `ms` on, firing the timer at each due time on the way.
    func run(ms: Double) {
        let end = clock.now + UInt64(ms * 1_000_000)
        while let at = fireAt, at <= end, let pending = fire {
            clock.now = max(clock.now, at)
            fireAt = nil
            fire = nil
            fires += 1
            pending()
        }
        clock.now = max(clock.now, end)
    }
}

@MainActor
private final class FakeDeadlines: IdleNextDeadlineSource {
    var nextFireNanos: UInt64?
    var onNextFireChange: (@MainActor () -> Void)?
}

/// Other schedulers' display links, flipped and ticked by hand.
@MainActor
private final class FakeOtherLinks: OtherFrameLinks {
    private(set) var anyRunning = false
    private var subscriptions: [FrameLinksSubscription] = []

    func add(_ subscription: FrameLinksSubscription) { subscriptions.append(subscription) }

    func set(running: Bool) {
        anyRunning = running
        for subscription in subscriptions { subscription.changed(running) }
    }

    func frame(timestamp: CFTimeInterval, refreshInterval: Double) {
        for subscription in subscriptions { subscription.frame(timestamp, refreshInterval) }
    }
}

@MainActor
private final class IdleFakeInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// Keeps the budgeted link up with an always-active frame client.
@MainActor
private final class IdleLinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

@MainActor
private final class IdleFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
