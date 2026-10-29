@testable import CmuxNextChromiumWarmup
import CmuxNextInputCoreTestSupport
import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// The warmup on the real main-thread scheduler (`MainDeadlineScheduler: ChromiumWarmupIdle`, the
/// app's wiring), with a fake clock, a fake idle period timer and a fake link (p06-scheduler-050
/// acceptance: the refill never runs inside an input response; past its 500 ms `maxDelay` it runs
/// as background work when no idle period comes).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChromiumWarmupSchedulerTests {
    let rig = WarmupRig()

    /// A take's refill report during an open input response: the idle task builds nothing until the
    /// response closes, then the next long period builds the spare.
    @Test func theRefillNeverRunsInsideAnInputResponse() async {
        let engine = FakeWarmupEngine()
        let warmup = rig.warmup(engine)
        rig.timer.run(ms: 51)
        #expect(rig.work.idle.count == 0, "the launch check ran")

        rig.work.noteDiscreteInput(expectsFrame: true)
        #expect(rig.work.budget.isInputResponseOpen)
        engine.onSpareWindowNeeded?()
        #expect(engine.prepared.isEmpty, "nothing is built in the take's turn")
        rig.timer.run(ms: 60)
        #expect(engine.prepared.isEmpty, "the refill ran inside the input response")

        rig.work.budget.noteUserBlockingCommit()
        #expect(!rig.work.budget.isInputResponseOpen)
        // The next long period, or (while the response's requested tick keeps the link up) the
        // refill's maxDelay, builds it.
        rig.timer.run(ms: 600)
        await spinMainRunLoop { !engine.prepared.isEmpty }
        #expect(engine.prepared == [false], "the spare is built once the response closed")
        warmup.stop()
    }

    /// A frame client keeps the link running, so no long period comes: past 500 ms the refill moves
    /// to background work and builds the spare there.
    @Test func pastItsMaxDelayTheRefillRunsAsBackgroundWorkWithNoIdlePeriod() async {
        let engine = FakeWarmupEngine()
        let warmup = rig.warmup(engine)
        rig.timer.run(ms: 51)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: rig.work.frames) { _ in true }
        keeper.activate()

        engine.onSpareWindowNeeded?()
        rig.timer.run(ms: 400)
        #expect(engine.prepared.isEmpty, "no idle period while frames run, and the delay has not passed")
        rig.timer.run(ms: 150)
        await spinMainRunLoop { !engine.prepared.isEmpty }
        #expect(engine.prepared == [false], "past maxDelay the refill ran as background work")
        keeper.deactivate()
        warmup.stop()
    }
}

/// The real scheduler on a fake clock, timer and link.
@MainActor
final class WarmupRig {
    let clock: WarmupClock
    let timer: WarmupIdleTimer
    let work: MainWorkScheduler
    let deadlines: MainDeadlineScheduler
    let input = FakeInputTap()

    init() {
        let clock = WarmupClock(), timer = WarmupIdleTimer(clock: clock)
        self.clock = clock
        self.timer = timer
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: WarmupNoInput(), uptimeNanos: clock.read), idleTimer: timer) { _ in
            WarmupFakeLink()
        }
        deadlines = MainDeadlineScheduler(work: work)
    }

    /// A started warmup on the rig (Chromium not the default; its launch check is posted).
    func warmup(_ engine: FakeWarmupEngine) -> ChromiumWarmup {
        let warmup = ChromiumWarmup(engine: engine, idle: deadlines, input: input, memory: ManualMemoryLevelRegistry(),
                                    isTrackingMenu: { false },
                                    observeMenuEnd: { _ in NSObject() })
        warmup.start(defaultIsChromium: { false })
        return warmup
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
final class WarmupClock {
    var now: UInt64 = 10_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}

/// The idle period timer, fired by moving the clock.
@MainActor
final class WarmupIdleTimer: IdlePeriodTimer {
    private let clock: WarmupClock
    private var fire: (@MainActor () -> Void)?
    private var fireAt: UInt64?

    init(clock: WarmupClock) { self.clock = clock }

    func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void) {
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
            pending()
        }
        clock.now = max(clock.now, end)
    }
}

@MainActor
final class WarmupNoInput: InputPendingSource {
    func hasPendingInput(uptime: TimeInterval) -> Bool { false }
}

@MainActor
final class WarmupFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
    func requestFrameRate(_ range: CAFrameRateRange) {}
}

/// Runs main run loop passes and the main actor's queued jobs (the promoted background turn) until `done` or 5 s.
/// The frame that runs the promoted task is the display clock's stall tick (the fake link never fires), which its
/// `DemandTimer` delivers as a main-actor job. The test body is itself a main-queue job, and a run loop nested in one
/// never drains the main queue, so each pass also suspends the test to let that job run.
@MainActor
private func spinMainRunLoop(until done: () -> Bool) async {
    let end = Date(timeIntervalSinceNow: 5)
    while !done(), Date() < end {
        runLoopPass()
        await Task.yield()
    }
}

/// One main run loop pass of at most 10 ms; a sync call, as `RunLoop.run(mode:before:)` is unavailable from async code.
@MainActor
private func runLoopPass() {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}
