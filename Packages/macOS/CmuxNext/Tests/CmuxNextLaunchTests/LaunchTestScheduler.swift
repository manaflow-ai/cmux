import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// A ``StartupScheduler`` on hand-run frames, a hand-run main hop and a manual failsafe clock; its
/// launch phase is already settled, so the scheduler arms its own failsafe on ``clock``.
@MainActor
final class LaunchTestScheduler {
    let clock: ManualClock
    let hand: LaunchTestHop
    let mainWork: MainWorkScheduler
    let startup: StartupScheduler
    private let uptime: LaunchTestUptime
    private var timestamp = 0.0

    init() {
        let clock = ManualClock(), hand = LaunchTestHop(), uptime = LaunchTestUptime()
        // The frame scheduler's stall timer sleeps on its own clock, so the failsafe is the only sleeper on `clock`.
        let mainWork = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { uptime.now }), clock: ManualClock(),
                                                 ledger: WakeupLedger()) { _ in LaunchTestLink() }
        (self.clock, self.hand, self.uptime, self.mainWork) = (clock, hand, uptime, mainWork)
        startup = StartupScheduler(mainWork: mainWork, background: BackgroundWork(label: "test.launch"), hop: hand.hop,
                                   clock: clock, ledger: WakeupLedger(), log: StartupTaskLog())
    }

    /// One display frame, 17 ms after the last.
    func fire() {
        uptime.advance(by: 17_000_000)
        timestamp += 1
        mainWork.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    /// Releases the registration and first-frame refs and runs the posted completion, if due.
    func completeImplicitRefs() {
        startup.finishRegistration()
        startup.firstFrameCommitted()
        hand.drain()
    }
}

/// A main hop the test runs by hand.
nonisolated final class LaunchTestHop: Sendable {
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

/// The budget's uptime, advanced by the frames.
nonisolated final class LaunchTestUptime: Sendable {
    private let state = Mutex<UInt64>(1_000_000_000)

    var now: UInt64 { state.withLock { $0 } }

    func advance(by nanos: UInt64) { state.withLock { $0 += nanos } }
}

private final class LaunchTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
