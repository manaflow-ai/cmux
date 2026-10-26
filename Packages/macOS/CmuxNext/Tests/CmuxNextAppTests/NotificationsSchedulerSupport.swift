@testable import CmuxNextApp
import CmuxNextWakeups
import QuartzCore

/// Notification tests that never reach a frame use a service on a scheduler of its own; the app
/// passes the composition root's scheduler and deadlines (`AppServices.notifications`).
extension NotificationCenterService {
    convenience init() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        self.init(work: work, deadlines: MainDeadlineScheduler(work: work))
    }
}

/// The app's scheduler on a fake display link the test fires (``frame()``), on a clock that moves
/// one frame per frame, so service observations flush only when the test says a frame came.
@MainActor
struct NotificationFrames {
    let work: MainWorkScheduler
    let deadlines: MainDeadlineScheduler
    private let clock: NotificationFrameClock

    /// - Parameter input: The person's pending input the budget yields to (default: none).
    init(input: any InputPendingSource = NoInputPending()) {
        let clock = NotificationFrameClock()
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in NotificationFrameLink() }
        deadlines = MainDeadlineScheduler(work: work)
    }

    /// A service on this scheduler.
    func service() -> NotificationCenterService {
        NotificationCenterService(work: work, deadlines: deadlines)
    }

    /// One display frame, a frame period after the last.
    func frame() {
        clock.advance()
        work.frameDidFire(timestamp: clock.seconds, refreshInterval: 1.0 / 60)
    }
}

/// `CLOCK_UPTIME_RAW` nanoseconds that move only by a frame.
@MainActor
private final class NotificationFrameClock {
    private var now: UInt64 = 1_000_000_000
    // Strong: the scheduler's stall timer may read it after the test returned.
    var read: () -> UInt64 { { [self] in now } }
    var seconds: CFTimeInterval { CFTimeInterval(now) / 1e9 }
    func advance() { now += 16_666_667 }
}

@MainActor
private final class NotificationFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
