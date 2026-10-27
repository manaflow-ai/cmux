import CmuxNextWakeups
import Foundation

/// A main-thread scheduler whose turns, idle periods and clock the test drives
/// (p06-scheduler-321's harness): a post runs only when the test runs its turn or fires a frame,
/// so a case reads what was posted, in which class and for which owner, before it runs.
@MainActor final class BrowserSweepRig {
    /// The uptime the budget, the idle periods and the nodes read (`CLOCK_UPTIME_RAW` ns in the app).
    final class Clock {
        var now: UInt64 = 10_000_000_000
        var read: () -> UInt64 { { [self] in self.now } }
        var uptime: VisibilityNode.Uptime { { [self] in .nanoseconds(Int64(self.now)) } }
        var seconds: Double { Double(now) / 1_000_000_000 }
    }

    /// The scheduler's queued run loop turns, run by ``drain()``.
    final class Turns {
        var queued: [@MainActor () -> Void] = []
        func perform(_ turn: @escaping @MainActor () -> Void) { queued.append(turn) }
    }

    /// The idle period timer, fired by moving the clock.
    final class IdleTimer: IdlePeriodTimer {
        private let clock: Clock
        private var fire: (@MainActor () -> Void)?
        private var fireAt: UInt64?

        init(clock: Clock) { self.clock = clock }

        func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void) {
            fireAt = clock.now + delay
            self.fire = fire
        }

        func cancel() {
            fireAt = nil
            fire = nil
        }

        /// Moves the clock `ms` on, firing the timer at each due time on the way.
        func run(ms: Double) {
            let end = clock.now + UInt64(ms * 1_000_000)
            while let at = fireAt, at <= end, let pending = fire {
                clock.now = max(clock.now, at)
                fireAt = nil
                fire = nil
                pending()
            }
            clock.now = max(clock.now, end)
        }
    }

    /// A display link fired by hand (``drain()``).
    final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    let clock: Clock
    let timer: IdleTimer
    let turns: Turns
    let work: MainWorkScheduler

    init() {
        let clock = Clock(), turns = Turns()
        let timer = IdleTimer(clock: clock)
        (self.clock, self.timer, self.turns) = (clock, timer, turns)
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), ledger: WakeupLedger(),
                                         performTurn: { turn in turns.perform(turn) }, idleTimer: timer) { _ in Link() }
    }

    /// Runs the queued turns and fires frames until nothing posted is left (bounded).
    func drain() {
        for _ in 0..<20 {
            while !turns.queued.isEmpty { turns.queued.removeFirst()() }
            if BudgetedWorkClass.allCases.allSatisfy({ work.postedCount($0) == 0 }) { return }
            clock.now += 17_000_000
            work.frameDidFire(timestamp: clock.seconds, refreshInterval: 1.0 / 60)
        }
    }

    /// The classes `owner`'s finished tasks ran in, from the board's owner ledger.
    func classes(of owner: String) -> Set<MainWorkClass> {
        Set(work.board.ownerSnapshot().owners.filter { $0.owner == owner }.map(\.workClass))
    }

    /// How many of `owner`'s tasks ran.
    func runs(of owner: String) -> Int {
        work.board.ownerSnapshot().owners.filter { $0.owner == owner }.reduce(0) { $0 + $1.tasks }
    }

    /// Lets the main actor run other jobs (a query's off-main reader posting its delivery) until `done`,
    /// for at most two seconds.
    func spin(until done: () -> Bool) async {
        let limit = ContinuousClock.now + .seconds(2)
        while !done(), ContinuousClock.now < limit { await Task.yield() }
    }
}
