import CmuxNextWakeups

/// The repair's main-thread scheduler with no display link and no run loop: a follow's flush is a posted turn, and
/// the test runs the queued turns itself (``run()``), so nothing runs between a change and the run but that change.
@MainActor
final class RepairTurns {
    private final class Queue {
        var turns: [@MainActor () -> Void] = []
    }

    private let queue: Queue
    /// The scheduler the repair under test follows its store on.
    let work: MainWorkScheduler

    init() {
        let queue = Queue()
        self.queue = queue
        work = MainWorkScheduler.testing(performTurn: { queue.turns.append($0) }) { _ in nil }
    }

    /// Turns queued and not run yet.
    var pending: Int { queue.turns.count }

    /// Runs every queued turn, and the turns they queue, in order.
    func run() {
        while !queue.turns.isEmpty { queue.turns.removeFirst()() }
    }
}
