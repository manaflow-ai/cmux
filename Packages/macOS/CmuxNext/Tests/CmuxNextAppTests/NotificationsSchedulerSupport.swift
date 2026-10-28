@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextWakeups
import QuartzCore

/// Notification tests that never reach a frame use a service on a scheduler of its own; the app
/// passes the composition root's scheduler, deadlines and background work (`AppServices.notifications`).
extension NotificationCenterService {
    convenience init() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        self.init(work: work, deadlines: MainDeadlineScheduler(work: work), background: BackgroundWork(label: "test.notifications"))
    }
}

/// The app's scheduler on a fake display link the test fires (``frame()``), and its deadlines on a
/// wake-up queue whose timer never touches the run loop (``advance(by:)``), both on one uptime that
/// only the test moves: service observations flush only when the test says a frame came, and a
/// deadline runs only when the test moves the clock past it.
@MainActor
struct NotificationFrames {
    let work: MainWorkScheduler
    let deadlines: MainDeadlineScheduler
    private let uptime: NotificationUptime
    private let wakeUps: MainWakeUpQueue

    /// - Parameter input: The person's pending input the budget yields to (default: none).
    init(input: any InputPendingSource = NoInputPending()) {
        let uptime = NotificationUptime()
        self.uptime = uptime
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: { uptime.now })) { _ in NotificationFrameLink() }
        wakeUps = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            NotificationWakeTimer()
        }
        deadlines = MainDeadlineScheduler(work: work, queue: wakeUps)
    }

    /// A service on this scheduler and these deadlines.
    func service() -> NotificationCenterService {
        NotificationCenterService(work: work, deadlines: deadlines, background: BackgroundWork(label: "test.notifications"))
    }

    /// One display frame, a frame period after the last.
    func frame() {
        uptime.advance(by: 16_666_667)
        work.frameDidFire(timestamp: CFTimeInterval(uptime.now) / 1e9, refreshInterval: 1.0 / 60)
    }

    /// Moves the clock `duration` on and runs the deadlines due by then, as the queue's timer would;
    /// then one frame runs the actions they posted in their class.
    func advance(by duration: Duration) {
        uptime.advance(by: duration.nanosecondCount)
        wakeUps.fire()
        frame()
    }
}

/// `CLOCK_UPTIME_RAW` nanoseconds that move only when the test moves them; the wake-up queue reads
/// it from any thread.
nonisolated final class NotificationUptime: Sendable {
    private let state = Mutex<UInt64>(1_000_000_000)

    var now: UInt64 { state.withLock { $0 } }

    func advance(by nanos: UInt64) { state.withLock { $0 += nanos } }
}

/// A timer the queue arms and parks; ``NotificationFrames/advance(by:)`` fires the queue itself.
nonisolated private final class NotificationWakeTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

@MainActor
private final class NotificationFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
