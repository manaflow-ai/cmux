import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Dispatch
import os
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

    @Test func theSchedulerHoldsBackgroundAndIdleEnqueuesUntilTheirPhase() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let work = MainWorkScheduler.testing(startup: startup) { _ in StartupFakeLink() }
        var ran: [String] = []
        work.whenStartupAdmitsIdle { ran.append("idle") }
        work.whenStartupAdmits(.background) { ran.append("background") }
        work.whenStartupAdmits(.automation) { ran.append("automation") }
        work.whenStartupAdmits(.visible) { ran.append("visible") }
        #expect(ran == ["automation", "visible"])
        startup.noteLaunch(.hidden)
        #expect(ran == ["automation", "visible", "background"])
        startup.markDone(.firstSnapshot)
        startup.markDone(.restoreDone)
        startup.markDone(.visiblePageIdle)
        #expect(ran == ["automation", "visible", "background", "idle"])
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

    /// The off-main best-effort fence (p06-scheduler-204): a posted best-effort item waits for the
    /// reveal on every lane while user-visible work runs, and the reveal releases them in post order.
    @Test(arguments: BlockingLane.allCases)
    func aBestEffortPostWaitsForTheReveal(lane: BlockingLane) async {
        let queued = BackgroundWorkTests.Started()
        let finished = BackgroundWorkTests.Started()
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        // One cpu slot, so the release order is the run order on every lane but system (six slots).
        let work = BackgroundWork(cpuWidth: 1, label: "test.startup.fence", onQueued: { _, _ in queued.signal() })
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        startup.fenceBestEffort(work)
        for name in ["a", "b", "c"] {
            work.post(.bestEffort, mayBlock: lane) {
                log.withLock { $0.append(name) }
                finished.signal()
            }
        }
        // Queued, not started, although the lane's slots are free.
        await queued.wait(3)

        // User-visible and user-blocking posts on the same lane run at once while launching.
        let above = BackgroundWorkTests.Started()
        work.post(.userVisible, mayBlock: lane) { above.signal() }
        work.post(.userBlocking, mayBlock: lane) { above.signal() }
        await above.wait(2)
        #expect(log.withLock { $0 }.isEmpty, "best effort waits for the reveal")
        #expect(startup.phase == .launching)

        startup.noteFirstFrame()
        await finished.wait(3)
        if lane == .system {
            #expect(Set(log.withLock { $0 }) == ["a", "b", "c"])
        } else {
            #expect(log.withLock { $0 } == ["a", "b", "c"], "the reveal releases them in post order")
        }
        // Once revealed nothing is held.
        work.post(.bestEffort, mayBlock: lane) { finished.signal() }
        await finished.wait()
    }

    /// Raising the fence does not wait for a best-effort item that already runs; it holds only
    /// the items posted after it.
    @Test func theFenceDoesNotWaitForARunningItem() async {
        let started = BackgroundWorkTests.Started()
        let queued = BackgroundWorkTests.Started()
        let finished = BackgroundWorkTests.Started()
        let gate = DispatchSemaphore(value: 0)
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        // Two cpu slots: the held item has a free slot and still waits.
        let work = BackgroundWork(cpuWidth: 2, label: "test.startup.running", onQueued: { _, _ in queued.signal() })
        work.post(.bestEffort, mayBlock: .cpu) {
            started.signal()
            gate.wait()
            log.withLock { $0.append("running") }
            finished.signal()
        }
        await started.wait()

        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        // Returns while the running item is still blocked on the gate.
        startup.fenceBestEffort(work)
        work.post(.bestEffort, mayBlock: .cpu) {
            log.withLock { $0.append("held") }
            finished.signal()
        }
        await queued.wait()
        gate.signal()
        await finished.wait()
        #expect(log.withLock { $0 } == ["running"], "the running item finishes; the later one is held")

        startup.noteLaunch(.hidden)
        await finished.wait()
        #expect(log.withLock { $0 } == ["running", "held"])
    }

    /// The reveal deadline lowers the fence too, and a phase that is already revealed or settled
    /// raises none.
    @Test func theDeadlineEndsTheFenceAndALaterPhaseRaisesNone() async throws {
        let queued = BackgroundWorkTests.Started()
        let finished = BackgroundWorkTests.Started()
        let clock = ManualClock()
        let startup = StartupPhase(clock: clock, ledger: WakeupLedger())
        let work = BackgroundWork(label: "test.startup.deadline", onQueued: { _, _ in queued.signal() })
        startup.fenceBestEffort(work)
        work.post(.idle, mayBlock: .files) { finished.signal() }
        await queued.wait()
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1_500))
        await reached(.revealed, startup)
        await finished.wait()

        startup.fenceBestEffort(work)
        work.post(.bestEffort, mayBlock: .files) { finished.signal() }
        await finished.wait()

        let settled = StartupPhase.settled()
        let other = BackgroundWork(label: "test.startup.settled")
        settled.fenceBestEffort(other)
        other.post(.bestEffort, mayBlock: .files) { finished.signal() }
        await finished.wait()
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
