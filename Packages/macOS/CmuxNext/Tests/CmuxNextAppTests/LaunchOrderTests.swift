import CmuxNextCompat
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's order owners at the composition root (p08-startup-012): the best-effort fence
/// `main()` raises comes down at startup complete after the `startup_complete` marks, and the
/// restore ref ends with the reason its restore had.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchOrderTests {
    @Test func completionMarksTheReasonThenLowersTheFence() async {
        let f = LaunchOrderFixture()
        f.background.beginBestEffortFence()
        var marks: [String] = []
        f.order.endFenceAtCompletion(f.background) { marks.append($0) }
        let ran = LaunchOrderFlag()
        let (idleRan, idleDone) = AsyncStream<Void>.makeStream()
        f.background.post(.idle, mayBlock: .files) {
            ran.set()
            idleDone.finish()
        }
        f.order.startup.finishRegistration()
        #expect(marks.isEmpty, "the first-frame ref is still held")
        #expect(!ran.isSet, "idle lane work waits behind the fence until startup completes")
        f.order.startup.firstFrameCommitted()
        f.hand.drain()
        #expect(marks == ["startup_complete.firstFrameCommitted", "startup_complete"], "the reason first: a bench that waits for the mark has it")
        for await _ in idleRan {}
        #expect(ran.isSet, "the fence came down at completion")
    }

    @Test func theRestoreRefHoldsStartupUntilRestoreRan() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let f = LaunchOrderFixture(phase: phase)
        let restored = f.order.restoreHold { false }
        f.complete()
        #expect(f.order.startup.completion == nil)
        #expect(f.order.startup.heldRefs.contains("WindowManager.restore"))
        restored(1)
        #expect(!f.order.startup.heldRefs.contains("WindowManager.restore"))
        phase.noteFirstFrame()
        for reference in [StartupPhase.Reference.firstSnapshot, .restoreDone, .visiblePageIdle] { phase.markDone(reference) }
        f.hand.drain()
        #expect(f.order.startup.completion?.reason == .launchPhaseSettled, "the restore ref ended before the phase it feeds")
    }

    @Test func aDaemonThatNeverLoadsEndsTheRestoreRefAtTheSettle() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let f = LaunchOrderFixture(phase: phase)
        _ = f.order.restoreHold { true }
        f.complete()
        #expect(f.order.startup.heldRefs.contains("WindowManager.restore"))
        // StartupReferences marks every reference done when the daemon is unavailable; restore never runs.
        phase.noteFirstFrame()
        for reference in [StartupPhase.Reference.firstSnapshot, .restoreDone, .visiblePageIdle] { phase.markDone(reference) }
        f.hand.drain()
        #expect(f.order.startup.completion?.reason == .daemonUnavailable, "not the failsafe: the settle ended the restore ref")
    }
}

/// A launch order on hand-run frames, a hand-run main hop and manual clocks.
@MainActor
final class LaunchOrderFixture {
    let hand: LaunchOrderHandHop
    let background: BackgroundWork
    let order: LaunchOrder
    private let uptime: LaunchOrderUptime
    private var timestamp = 0.0

    /// - Parameter phase: The launch phase (default: already settled, so the scheduler arms its own failsafe).
    init(phase: StartupPhase = .settled()) {
        let hand = LaunchOrderHandHop()
        let background = BackgroundWork(label: "test.launch-order")
        let uptime = LaunchOrderUptime()
        let mainWork = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { uptime.now }), clock: ManualClock(),
                                                 ledger: WakeupLedger(), startup: phase) { _ in LaunchOrderLink() }
        self.hand = hand
        self.background = background
        self.uptime = uptime
        order = LaunchOrder(mainWork: mainWork,
                            startup: StartupScheduler(mainWork: mainWork, background: background, hop: hand.hop, clock: ManualClock(),
                                                      ledger: WakeupLedger(), log: StartupTaskLog()))
    }

    /// One display frame, 17 ms after the last.
    func fire() {
        uptime.advance(by: 17_000_000)
        timestamp += 1
        order.mainWork.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    /// Releases both implicit refs and runs the posted completion.
    func complete() {
        order.startup.finishRegistration()
        order.startup.firstFrameCommitted()
        hand.drain()
    }
}

/// The budget's uptime, advanced by the fixture's frames.
nonisolated final class LaunchOrderUptime: Sendable {
    private let state = Mutex<UInt64>(1_000_000_000)

    var now: UInt64 { state.withLock { $0 } }

    func advance(by nanos: UInt64) { state.withLock { $0 += nanos } }
}

/// Set once from a lane thread, read on main.
nonisolated final class LaunchOrderFlag: Sendable {
    private let state = Mutex<Bool>(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }
}

/// A main hop the test runs by hand.
nonisolated final class LaunchOrderHandHop: Sendable {
    private let queued = Mutex<[@MainActor @Sendable () -> Void]>([])

    var hop: StartupMainHop {
        StartupMainHop { [self] work in queued.withLock { $0.append(work) } }
    }

    /// Runs every queued hop, and the hops they queue.
    @MainActor func drain() {
        while true {
            let batch = queued.withLock { queued -> [@MainActor @Sendable () -> Void] in
                defer { queued = [] }
                return queued
            }
            if batch.isEmpty { return }
            for work in batch { work() }
        }
    }
}

private final class LaunchOrderLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
