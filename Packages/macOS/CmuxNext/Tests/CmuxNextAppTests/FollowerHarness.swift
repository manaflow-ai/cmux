import CmuxNextWakeups
import Foundation

/// The app's main-thread scheduler on a frame link the test fires, at a clock the test moves, with an input source
/// the test sets: the harness of p06-scheduler rule 9 for a migrated follower (an automation flush yields to pending
/// input; a person's change applies in the input-response pass, before the commit). A post waits for ``frame()``.
@MainActor
final class FollowerHarness {
    let input: FollowerInputPending
    let work: MainWorkScheduler
    private let clock: FollowerClock
    /// Keeps the display link up, so a post waits for the test's frames, not a run loop turn.
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let input = FollowerInputPending(), clock = FollowerClock()
        self.input = input
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in FollowerFrameLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// One display frame, 17 ms after the last one.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    /// Stops the frames.
    func stop() {
        keeper.deactivate()
    }
}

/// Input the person has not delivered yet, as the test says.
@MainActor
final class FollowerInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// `CLOCK_UPTIME_RAW` nanoseconds the test moves; `read` holds the clock (the budget keeps only the closure).
@MainActor
final class FollowerClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in now } }
    func advance(ms: Double) { now += UInt64((ms * 1_000_000).rounded()) }
}

private final class FollowerFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
