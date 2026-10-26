import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The startup phases (StartupPhase.swift; p06-scheduler.md section A): launching holds background
/// and idle work, the reveal comes at the first frame, at once for a hidden launch, or at the
/// 1.5 s deadline, and the settle waits for every reference or the 10 s failsafe.
@MainActor @Suite(.timeLimit(.minutes(1))) struct StartupPhaseTests {
    @Test func heldBodiesRunInPostOrderAtTheirPhaseChange() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        var ran: [String] = []
        startup.whenReached(MainWorkClass.background.startupOpening) { ran.append("background 1") }
        startup.whenReached(.settled) { ran.append("idle 1") }
        startup.whenReached(MainWorkClass.background.startupOpening) { ran.append("background 2") }
        startup.whenReached(.settled) { ran.append("idle 2") }
        startup.whenReached(MainWorkClass.background.startupOpening) { ran.append("background 3") }
        #expect(ran.isEmpty, "nothing held runs while launching")

        startup.noteFirstFrame()
        #expect(startup.phase == .revealed)
        #expect(ran == ["background 1", "background 2", "background 3"])

        startup.whenReached(.revealed) { ran.append("background 4") }
        #expect(ran.last == "background 4", "a post after the reveal runs at once")

        startup.markDone(.firstSnapshot)
        startup.markDone(.restoreDone)
        startup.markDone(.visiblePageIdle)
        #expect(startup.phase == .settled)
        #expect(ran == ["background 1", "background 2", "background 3", "background 4", "idle 1", "idle 2"])
    }

    @Test func visibleAndAutomationAreNeverGated() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        #expect(startup.phase == .launching)
        for workClass in [MainWorkClass.input, .frame, .visible, .automation] {
            #expect(startup.admits(workClass), "\(workClass) runs while launching")
            var ran = false
            startup.whenReached(workClass.startupOpening) { ran = true }
            #expect(ran, "\(workClass) is not held")
        }
        #expect(!startup.admits(.background))
        #expect(!startup.admitsIdle)
    }

    /// A launch whose window never draws (no window shows, or its first frame never comes) is
    /// revealed by the 1.5 s deadline.
    @Test func aLaunchWithNoFirstFrameIsRevealedAtTheDeadline() async throws {
        let clock = ManualClock()
        let startup = StartupPhase(clock: clock, ledger: WakeupLedger())
        startup.noteLaunch(.window)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1_499))
        #expect(startup.phase == .launching, "no reveal before 1.5 s")
        clock.advance(by: .milliseconds(1))
        await reached(.revealed, startup)
        #expect(startup.revealCause == .deadline)
        #expect(startup.admits(.background))
        #expect(!startup.admitsIdle, "the deadline is not a frame: the settle still waits")
        #expect(startup.pendingReferences.contains(.firstFrame))
    }

    @Test func aHiddenLaunchIsRevealedAtOnce() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        var ran = false
        startup.whenReached(MainWorkClass.background.startupOpening) { ran = true }
        startup.noteLaunch(.hidden)
        #expect(startup.phase == .revealed)
        #expect(startup.revealCause == .hidden)
        #expect(ran)
        #expect(!startup.pendingReferences.contains(.firstFrame), "a hidden launch waits for no frame")
    }

    @Test func aLaunchWithNoWindowIsRevealedAtOnce() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        startup.noteLaunch(.noWindow)
        #expect(startup.phase == .revealed)
        #expect(startup.revealCause == .noWindow)
    }

    @Test func settledWaitsForEveryReference() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        startup.markDone(.firstSnapshot)
        startup.markDone(.restoreDone)
        startup.markDone(.visiblePageIdle)
        #expect(startup.phase == .launching, "references alone do not reveal")
        startup.noteFirstFrame()
        #expect(startup.phase == .settled)
        #expect(startup.settleCause == .references)

        let other = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        other.noteFirstFrame()
        other.markDone(.firstSnapshot)
        other.markDone(.firstSnapshot)
        other.markDone(.restoreDone)
        #expect(other.phase == .revealed, "one reference is still pending")
        #expect(other.pendingReferences == [.visiblePageIdle])
        other.markDone(.visiblePageIdle)
        #expect(other.phase == .settled)
    }

    @Test func theFailsafeSettlesTenSecondsAfterLaunch() async throws {
        let clock = ManualClock()
        let startup = StartupPhase(clock: clock, ledger: WakeupLedger())
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1_500))
        await reached(.revealed, startup)
        // The failsafe counts from launch, not from the reveal.
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(8_499))
        #expect(startup.phase == .revealed)
        var idleRan = false
        startup.whenReached(.settled) { idleRan = true }
        clock.advance(by: .milliseconds(1))
        await reached(.settled, startup)
        #expect(startup.settleCause == .failsafe)
        #expect(idleRan)
        #expect(startup.pendingReferences == Set(StartupPhase.Reference.allCases), "no reference came")
        #expect(clock.sleeperCount == 0, "a settled phase has no timer")
    }

    @Test func anEarlyRevealKeepsTheFailsafeAtTenSeconds() async throws {
        let clock = ManualClock()
        let startup = StartupPhase(clock: clock, ledger: WakeupLedger())
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(200))
        startup.noteFirstFrame()
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(9_799))
        #expect(startup.phase == .revealed)
        clock.advance(by: .milliseconds(1))
        await reached(.settled, startup)
        #expect(startup.settleCause == .failsafe)
    }

    @Test func awaitingHeldWorkWhileLaunchingIsReported() {
        var reports: [StartupPhase.HeldAwait] = []
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger()) { reports.append($0) }
        startup.checkAwait(.visible, owner: "sidebar")
        startup.checkAwait(.automation, owner: "control")
        #expect(reports.isEmpty, "visible and automation awaits are fine while launching")

        startup.checkAwait(.background, owner: "favicons")
        startup.checkIdleAwait(owner: "spell")
        #expect(reports.map(\.work) == ["background", "idle"])
        #expect(reports.map(\.owner) == ["favicons", "spell"])
        #expect(reports.allSatisfy { $0.phase == .launching && $0.file.hasSuffix("StartupPhaseTests.swift") })

        startup.noteFirstFrame()
        startup.checkAwait(.background, owner: "favicons")
        #expect(reports.count == 2, "background is open once revealed")
    }

    @Test func aSettledPhaseHoldsNothing() {
        let startup = StartupPhase.settled()
        #expect(startup.phase == .settled)
        #expect(startup.admits(.background))
        #expect(startup.admitsIdle)
        var ran = false
        startup.whenReached(.settled) { ran = true }
        #expect(ran)
    }

    @Test func aTestingSchedulerIsSettled() {
        let work = MainWorkScheduler.testing { _ in StartupFakeLink() }
        #expect(work.startup.phase == .settled)
    }

    /// A launching scheduler holds background posts out of its queue (visible and automation run),
    /// queues them in post order at the reveal without running any inside the phase change, and
    /// runs them on the next frame.
    @Test func theSchedulerHoldsBackgroundPostsUntilTheReveal() {
        let uptime = StartupUptime()
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read), startup: startup) { _ in StartupFakeLink() }
        let keeper = StartupLinkKeeper(on: work)
        var ran: [String] = []
        work.post(.background, owner: "favicons") { ran.append("background 1") }
        work.post(.visible, owner: "sidebar.rows") { ran.append("visible") }
        work.post(.automation, owner: "cli.request") { ran.append("automation") }
        work.post(.background, owner: "favicons") { ran.append("background 2") }
        #expect(work.postedCount(.background) == 0, "a held post is not in its class queue")
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran == ["visible", "automation"], "visible and automation run while launching")

        startup.noteFirstFrame()
        #expect(ran == ["visible", "automation"], "the reveal queues held posts; it never runs them inline")
        #expect(work.postedCount(.background) == 2)
        work.post(.background, owner: "favicons") { ran.append("background 3") }
        uptime.advance(ms: 17)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran == ["visible", "automation", "background 1", "background 2", "background 3"])
        keeper.stop()
    }

    /// Awaiting background work while launching is reported (a Debug assertion in the app); the
    /// await still finishes once the reveal opens background.
    @Test func awaitingABackgroundApplyWhileLaunchingIsReported() async {
        let uptime = StartupUptime()
        var reports: [StartupPhase.HeldAwait] = []
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger()) { reports.append($0) }
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read), startup: startup) { _ in StartupFakeLink() }
        let keeper = StartupLinkKeeper(on: work)
        let value = Task { @MainActor in await work.apply(.background, owner: "favicons.load") { 42 } }
        while reports.isEmpty { await Task.yield() }
        #expect(reports.map(\.work) == ["background"])
        #expect(reports.first?.owner == "favicons.load")
        #expect(reports.first?.phase == .launching)
        startup.noteFirstFrame()
        uptime.advance(ms: 17)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await value.value == 42)
        #expect(reports.count == 1)
        keeper.stop()
    }

    @Test func theSchedulerHoldsIdleEnqueuesUntilTheSettle() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let work = MainWorkScheduler.testing(startup: startup) { _ in StartupFakeLink() }
        var ran: [String] = []
        work.whenStartupAdmitsIdle { ran.append("idle 1") }
        work.whenStartupAdmitsIdle { ran.append("idle 2") }
        startup.noteLaunch(.hidden)
        #expect(ran.isEmpty, "idle waits for the settle, not the reveal")
        startup.markDone(.firstSnapshot)
        startup.markDone(.restoreDone)
        startup.markDone(.visiblePageIdle)
        #expect(ran == ["idle 1", "idle 2"])
        work.whenStartupAdmitsIdle { ran.append("idle 3") }
        #expect(ran.last == "idle 3", "an idle enqueue after the settle runs at once")
    }

    /// A held background body that finishes the last reference does not run idle work before the
    /// background bodies held after it.
    @Test func heldBackgroundRunsBeforeHeldIdleWhenItSettles() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        startup.markDone(.firstSnapshot)
        startup.markDone(.restoreDone)
        var ran: [String] = []
        startup.whenReached(.settled) { ran.append("idle") }
        startup.whenReached(.revealed) { ran.append("background 1"); startup.markDone(.visiblePageIdle) }
        startup.whenReached(.revealed) { ran.append("background 2") }
        startup.noteFirstFrame()
        #expect(ran == ["background 1", "background 2", "idle"])
        #expect(startup.settleCause == .references)
    }

    /// Returns once `startup` reaches `phase` (event-driven: the phase change runs the resume).
    private func reached(_ phase: StartupPhase.Phase, _ startup: StartupPhase) async {
        await withCheckedContinuation { continuation in
            startup.whenReached(phase) { continuation.resume() }
        }
    }
}

@MainActor
private final class StartupFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class StartupLinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// The budget's clock, moved by the test (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class StartupUptime {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}
