import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Dispatch
import Testing

/// The startup phases (StartupPhase.swift; p06-scheduler.md section A): launching holds background
/// work, the reveal comes at the first frame, at once for a hidden or windowless launch, or at the
/// 1.5 s deadline when a window's first frame never comes, and the settle waits for every
/// reference or the 10 s failsafe.
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
        for workClass in [MainWorkClass.input, .frame, .userBlocking, .visible, .automation] {
            #expect(startup.admits(workClass), "\(workClass) runs while launching")
            var ran = false
            startup.whenReached(workClass.startupOpening) { ran = true }
            #expect(ran, "\(workClass) is not held")
        }
        #expect(!startup.admits(.background))
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
        #expect(startup.phase == .revealed, "the deadline is not a frame: the settle still waits")
        #expect(startup.pendingReferences.contains(.firstFrame))
    }

    /// The reveal deadline fires (its timer claimed the fire) while main is busy, and the first
    /// frame reveals before the deadline's main hop runs: the stale deadline must not settle.
    @Test func aRevealDeadlineClaimedBeforeTheFirstFrameDoesNotSettle() async throws {
        let clock = ManualClock()
        // The ledger records the fire right after the timer claims it: that is the claim signal.
        let (claims, claimed) = AsyncStream.makeStream(of: Void.self)
        let startup = StartupPhase(clock: clock, ledger: WakeupLedger(uptime: { claimed.yield(); return 0 }))
        var settledAt: Duration?
        startup.whenReached(.settled) { settledAt = clock.now.offset }
        startup.noteLaunch(.window)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1_500))
        _ = await claims.first { @Sendable _ in true }
        // Main resumes here before the claimed deadline's hop: the frame comes first.
        startup.noteFirstFrame()
        #expect(startup.revealCause == .firstFrame)
        // The failsafe sleeps; by then the stale deadline action has had its turn on main.
        try await clock.waitForSleeper()
        #expect(startup.phase == .revealed, "a stale reveal deadline settled startup")
        #expect(startup.pendingReferences == [.firstSnapshot, .restoreDone, .visiblePageIdle])
        clock.advance(by: .milliseconds(8_500))
        await reached(.settled, startup)
        #expect(settledAt == .seconds(10), "settled at the failsafe, not at the stale deadline")
        #expect(startup.settleCause == .failsafe)
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
        #expect(reports.map(\.work) == [.background])
        #expect(reports.map(\.owner) == ["favicons"])
        #expect(reports.allSatisfy { $0.phase == .launching && $0.file.hasSuffix("StartupPhaseTests.swift") })

        startup.noteFirstFrame()
        startup.checkAwait(.background, owner: "favicons")
        #expect(reports.count == 1, "background is open once revealed")
    }

    @Test func aSettledPhaseHoldsNothing() {
        let startup = StartupPhase.settled()
        #expect(startup.phase == .settled)
        #expect(startup.admits(.background))
        var ran = false
        startup.whenReached(.settled) { ran = true }
        #expect(ran)
    }

    @Test func aTestingSchedulerIsSettled() {
        let work = MainWorkScheduler.testing { _ in StartupFakeLink() }
        #expect(work.startup.phase == .settled)
    }

    /// A launching scheduler holds background posts in their queue (visible and automation run),
    /// and runs them in post order from the frame after the reveal, never inside the phase change.
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
        #expect(work.postedCount(.background) == 2, "held posts wait, counted, in their class queue")
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran == ["visible", "automation"], "visible and automation run while launching")

        startup.noteFirstFrame()
        #expect(ran == ["visible", "automation"], "the reveal enables the class; it never runs held work inline")
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
        let (reports, report) = AsyncStream.makeStream(of: StartupPhase.HeldAwait.self)
        var count = 0
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger()) { count += 1; report.yield($0) }
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read), startup: startup) { _ in StartupFakeLink() }
        let keeper = StartupLinkKeeper(on: work)
        let value = Task { @MainActor in await work.apply(.background, owner: "favicons.load") { 42 } }
        // Event-driven: the report itself resumes the test.
        let first = await reports.first { @Sendable _ in true }
        #expect(first?.work == .background)
        #expect(first?.owner == "favicons.load")
        #expect(first?.phase == .launching)
        startup.noteFirstFrame()
        uptime.advance(ms: 17)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await value.value == 42)
        #expect(count == 1)
        keeper.stop()
    }

    /// A budgeted background queue on the scheduler (the FrameBatcher path, not a post) is held
    /// too: its client stays off the frame scheduler until the reveal.
    @Test func aBackgroundBatchQueueWaitsForTheReveal() {
        let uptime = StartupUptime()
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read), startup: startup) { _ in StartupFakeLink() }
        let keeper = StartupLinkKeeper(on: work)
        let background = FrameBatchQueue(owner: "test.background", budgeted: .background, on: work)
        let automation = FrameBatchQueue(owner: "test.automation", budgeted: .automation, on: work)
        var ran: [String] = []
        background.enqueue { ran.append("background 1") }
        automation.enqueue { ran.append("automation") }
        background.enqueue { ran.append("background 2") }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        uptime.advance(ms: 17)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran == ["automation"], "background batches wait while launching")
        #expect(background.count == 2)

        startup.noteFirstFrame()
        #expect(ran == ["automation"], "the reveal never runs a batch inline")
        uptime.advance(ms: 17)
        work.frameDidFire(timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(ran == ["automation", "background 1", "background 2"])
        keeper.stop()
    }

    /// A background client deactivated while held is not attached by the reveal, and a held
    /// client makes no display link.
    @Test func aClientDeactivatedWhileHeldStaysIdleAtTheReveal() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let work = MainWorkScheduler.testing(startup: startup) { _ in StartupFakeLink() }
        var ticks = 0
        let client = FrameClient(owner: "test.background", budgeted: .background, on: work) { _, _ in ticks += 1; return false }
        client.activate()
        #expect(client.isActive)
        #expect(!work.frames.hasLink, "a held client makes no display link")
        client.deactivate()
        startup.noteLaunch(.hidden)
        #expect(!work.frames.hasLink)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ticks == 0)
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

    /// Raising the launch fence only counts: a best-effort item that already runs is not
    /// waited on and finishes while the fence is up. A raise that waited for it would never return: the item
    /// waits for the test's release, sent after the raise. The reveal lowering the fence, user-visible work
    /// running at once and the held items' post order are LaunchOrderTests (CmuxNextAppTests), where the
    /// order wires the fence to the phase.
    @Test func theLaunchFenceDoesNotWaitForARunningItem() async {
        let started = LaneSignal<Bool>(), finished = LaneSignal<Bool>()
        let release = DispatchSemaphore(value: 0)
        let work = BackgroundWork(label: "test.startup.fence.running")
        work.post(.bestEffort, mayBlock: .files) {
            started.send(true)
            release.wait()
            finished.send(true)
        }
        #expect(await started.next() == true)
        let fence = work.raiseLaunchFence(cap: nil)
        release.signal()
        #expect(await finished.next() == true)
        #expect(fence.isUp, "the running item finished under the raised fence")
        fence.lower()
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

/// Values sent from lane bodies (synchronous), awaited by the test in send order.
private struct LaneSignal<Value: Sendable>: Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Value.self) }

    func send(_ value: Value) { continuation.yield(value) }

    func next() async -> Value? {
        for await value in stream { return value }
        return nil
    }
}
