import CmuxNextCompat

/// One item of a ``BackgroundWork`` lane: its body and the one-shot claim that runs or abandons it.
///
/// The scheduler may start an item while a cancel or a shutdown abandons it; whichever claims it first
/// wins, so a caller's continuation resumes exactly once and the shutdown count drops exactly once.
/// A job made with a ``TaskTrace/Ticket`` runs its body inside that post's `task.run` slice.
final class LaneJob: Sendable {
    let id: UInt64
    let shutdown: ShutdownBehavior
    /// The post's trace ticket; nil runs the body untraced.
    private let trace: TaskTrace.Ticket?
    /// The body; it gets the level the lane runs it at (a ``WorkSequence`` may raise it past its own priority).
    private let work: @Sendable (WorkPriority) -> Void
    private let abandoned: @Sendable () -> Void
    private let done: @Sendable () -> Void
    // concurrency-allow: one-shot claim checked synchronously by a lane thread, a cancel handler and shutdown (lock carve-out).
    private let claimed = Mutex(false)

    init(id: UInt64, shutdown: ShutdownBehavior, trace: TaskTrace.Ticket? = nil, work: @escaping @Sendable (WorkPriority) -> Void,
         abandoned: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        self.id = id
        self.shutdown = shutdown
        self.trace = trace
        self.work = work
        self.abandoned = abandoned
        self.done = done
    }

    /// Runs the body, at `priority`, the level of the slot that runs it, unless the item was abandoned first.
    func execute(at priority: WorkPriority) {
        guard claim() else { return }
        if let trace {
            trace.run(priority: TaskTrace.code(priority)) { work(priority) }
        } else {
            work(priority)
        }
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
