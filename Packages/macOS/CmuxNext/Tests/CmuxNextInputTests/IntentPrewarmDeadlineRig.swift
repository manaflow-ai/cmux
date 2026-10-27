import CmuxNextCompat
@testable import CmuxNextWakeups

/// The prewarm dwell's deadline scheduler on a wake-up queue whose timer never touches the run loop and
/// whose uptime only the test moves, and a main-thread scheduler whose posted work runs only in a
/// hand-fired frame (CmuxNextPagesTests' LifecycleDeadlineRig, for the input tests).
@MainActor
final class IntentPrewarmDeadlineRig {
    let queue: MainWakeUpQueue
    let scheduler: MainDeadlineScheduler
    private let uptime: RigUptime
    /// The main-thread scheduler whose posted work runs in ``fire(movingTime:)``'s frame.
    let work: MainWorkScheduler
    private let budgetClock: RigBudgetClock
    private let keeper: FrameClient
    private var frames: Double = 0

    init() {
        let uptime = RigUptime(), budgetClock = RigBudgetClock()
        self.uptime = uptime
        self.budgetClock = budgetClock
        queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            RigWakeUpTimer()
        }
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: budgetClock.read),
                                             ledger: WakeupLedger()) { _ in RigFrameLink() }
        self.work = work
        scheduler = MainDeadlineScheduler(work: work, queue: queue)
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Moves the uptime forward to `time`.
    func advance(to time: Duration) { uptime.now = max(uptime.now, time.nanosecondCount) }

    /// Runs the queue's wake (with `movingTime`, at its fire date, never earlier than now), then one
    /// frame, in which the actions it posted run.
    func fire(movingTime: Bool = true) {
        if movingTime, let date = scheduler.nextFireNanos { uptime.now = max(uptime.now, date) }
        queue.fire()
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }
}

/// A timer the queue arms and parks; the rig fires the queue itself. Nonisolated: the queue makes
/// timers off the main actor (the test target is main actor by default).
private nonisolated final class RigWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

@MainActor
private final class RigFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class RigUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

/// The frame budget's clock (`CLOCK_UPTIME_RAW` ns), one 60 Hz frame further at each fired frame.
@MainActor
private final class RigBudgetClock {
    var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}
