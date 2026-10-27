import CmuxNextCompat
@testable import CmuxNextWakeups

/// The store's MainWakeUpQueue on a timer that never touches the run loop and an uptime only the
/// test moves: ``advance(by:)`` moves it and runs the queue's fire, as the timer's callout would.
/// Its ``deadlines`` place a store's MainDeadlines (the resync retry, the stage bound, a command
/// recheck) on that queue and post their actions on ``work``, whose turns the test runs: ``advance(by:)``
/// runs them after the fire, ``runTurns()`` alone.
@MainActor final class DeadlineRig {
    let queue: MainWakeUpQueue
    /// The scheduler the deadlines' actions are posted on (no display link: each post is a queued turn).
    let work: MainWorkScheduler
    /// A deadline placer on ``queue`` and ``work``: pass it to `DaemonStore(waitDeadlines:deadlines:)`.
    let deadlines: MainDeadlineScheduler
    private let uptime: TestUptime
    private let turns: QueuedTurns

    init() {
        let uptime = TestUptime(), turns = QueuedTurns()
        self.uptime = uptime
        self.turns = turns
        queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            IdleWakeUpTimer()
        }
        work = MainWorkScheduler.testing(performTurn: { turns.queued.append($0) }) { _ in nil }
        deadlines = MainDeadlineScheduler(work: work, queue: queue)
    }

    /// Moves the uptime on by `duration`, fires the queue and runs the turns its deadlines posted.
    func advance(by duration: Duration) {
        uptime.advance(by: duration)
        queue.fire()
        runTurns()
    }

    /// Runs every queued turn, and the turns they queue, in order.
    func runTurns() {
        while !turns.queued.isEmpty { turns.queued.removeFirst()() }
    }
}

/// The turns the rig's scheduler queued and the test has not run.
@MainActor private final class QueuedTurns {
    var queued: [@MainActor () -> Void] = []
}

/// A timer the queue arms and parks; the rig fires the queue itself.
private final class IdleWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private final class TestUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 { value.load(ordering: .relaxed) }

    func advance(by duration: Duration) {
        value.store(now + duration.nanosecondCount, ordering: .relaxed)
    }
}
