import CmuxNextCompat
public import CmuxNextWakeups

/// A ``StartupScheduler`` on hand-run frames, a hand-run main hop and a manual failsafe clock: the
/// one startup scheduler fixture of the CmuxNext test targets (the scheduler's own tests, the launch
/// order and the launch's posts).
///
/// With the default `phase` (already settled) the scheduler arms its own failsafe on ``clock``; the
/// frame scheduler's stall timer sleeps on a clock of its own, so the failsafe is the only sleeper
/// there.
///
/// ```swift
/// let s = StartupTestScheduler()
/// s.startup.post(.afterStartup, "Palette.prepare.0", on: .main) { ran = true }
/// s.complete()   // registration and first-frame refs, then the posted completion
/// s.fire()       // one frame: the afterStartup task runs
/// ```
@MainActor
public final class StartupTestScheduler {
    /// The failsafe's clock.
    public let clock: ManualClock
    /// The scheduler's main hop (off-main posts and the posted completion), run by ``StartupTestHop/drain()``.
    public let hand: StartupTestHop
    /// The frame scheduler the afterFirstFrame and afterStartup main tasks run on.
    public let mainWork: MainWorkScheduler
    /// The lanes of lane tasks.
    public let background: BackgroundWork
    /// The scheduler under test.
    public let startup: StartupScheduler
    private let uptime: StartupTestUptime
    private var timestamp = 0.0

    /// - Parameters:
    ///   - phase: The frame scheduler's launch phase (default: settled, so the scheduler arms its own failsafe).
    ///   - input: The budget's pending-input source (a test that holds work behind input passes its own).
    ///   - criticalAllowlist: The names a critical post may have.
    ///   - background: The lanes (a test that raises a fence on them passes its own).
    ///   - firstIdle: The main loop's first idle (default: the registration, so ``complete()`` needs no run loop).
    public init(phase: StartupPhase = .settled(), input: any InputPendingSource = NoInputPending(),
                criticalAllowlist: [StaticString] = StartupScheduler.criticalAllowlist,
                background: BackgroundWork = BackgroundWork(label: "test.startup"),
                firstIdle: StartupFirstIdle = .atRegistration) {
        let clock = ManualClock(), hand = StartupTestHop(), uptime = StartupTestUptime()
        let mainWork = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: { uptime.now }),
                                                 clock: ManualClock(), ledger: WakeupLedger(), startup: phase) { _ in StartupTestLink() }
        (self.clock, self.hand, self.uptime, self.mainWork, self.background) = (clock, hand, uptime, mainWork, background)
        startup = StartupScheduler(mainWork: mainWork, background: background, hop: hand.hop, firstIdle: firstIdle, clock: clock,
                                   ledger: WakeupLedger(), criticalAllowlist: criticalAllowlist, log: StartupTaskLog())
    }

    /// One display frame, 17 ms after the last.
    public func fire() {
        uptime.advance(by: 17_000_000)
        timestamp += 1
        mainWork.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    /// Releases the registration and first-frame refs and runs the posted completion, if due.
    public func complete() {
        startup.finishRegistration()
        startup.firstFrameCommitted()
        hand.drain()
    }
}

/// The budget's uptime, advanced by the frames.
private final class StartupTestUptime: Sendable {
    private let state = Mutex<UInt64>(1_000_000_000)

    var now: UInt64 { state.withLock { $0 } }

    func advance(by nanos: UInt64) { state.withLock { $0 += nanos } }
}

@MainActor
private final class StartupTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
