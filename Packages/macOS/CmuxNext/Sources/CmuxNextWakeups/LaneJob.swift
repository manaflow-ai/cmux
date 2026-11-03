import CmuxNextCompat

/// One item of a ``BackgroundWork`` lane: its body and the one-shot claim that runs or abandons it.
///
/// The scheduler may start an item while a cancel or a shutdown abandons it; whichever claims it first
/// wins, so a caller's continuation resumes exactly once and the shutdown count drops exactly once.
final class LaneJob: Sendable {
    let id: UInt64
    let shutdown: ShutdownBehavior
    private let work: @Sendable () -> Void
    private let abandoned: @Sendable () -> Void
    private let done: @Sendable () -> Void
    // concurrency-allow: one-shot claim checked synchronously by a lane thread, a cancel handler and shutdown (lock carve-out).
    private let claimed = Mutex(false)

    init(id: UInt64, shutdown: ShutdownBehavior, work: @escaping @Sendable () -> Void,
         abandoned: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        self.id = id
        self.shutdown = shutdown
        self.work = work
        self.abandoned = abandoned
        self.done = done
    }

    /// Runs the body unless the item was abandoned first.
    func execute() {
        guard claim() else { return }
        work()
        done()
    }

    /// Gives the item up unless it has started: a waiting caller gets `CancellationError`.
    func abandon() {
        guard claim() else { return }
        abandoned()
        done()
    }

    private func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}
