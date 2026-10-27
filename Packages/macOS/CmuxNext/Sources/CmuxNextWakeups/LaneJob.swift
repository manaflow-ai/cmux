import CmuxNextCompat

/// One item of a ``BackgroundWork`` lane: its body and the one-shot claim that runs or abandons it.
///
/// The scheduler may start an item while a cancel or a shutdown abandons it; whichever claims it first
/// wins, so a caller's continuation resumes exactly once and the shutdown count drops exactly once.
/// A job made with a ``TaskTrace/Ticket`` ends its post's flow in the `task.run` slice its lane writes around the
/// run (``traceArrival()``).
final class LaneJob: Sendable {
    let id: UInt64
    let shutdown: ShutdownBehavior
    /// The post's trace ticket; nil writes no flow-in.
    private let trace: TaskTrace.Ticket?
    /// The body; it gets the level the lane runs it at (a ``WorkSequence`` may raise it past its own priority).
    private let work: @Sendable (WorkPriority) -> Void
    /// Gets the level the lane ran the body at and the body's start and end on the lane's clock, after the body
    /// and before `done`; nil when nothing reports the run (``BackgroundWork``'s `onRan`, the block-shutdown check).
    private let ran: (@Sendable (_ priority: WorkPriority, _ start: UInt64, _ end: UInt64) -> Void)?
    private let abandoned: @Sendable () -> Void
    private let done: @Sendable () -> Void
    // concurrency-allow: one-shot claim checked synchronously by a lane thread, a cancel handler and shutdown (lock carve-out).
    private let claimed = Mutex(false)

    init(id: UInt64, shutdown: ShutdownBehavior, trace: TaskTrace.Ticket? = nil,
         work: @escaping @Sendable (WorkPriority) -> Void,
         ran: (@Sendable (_ priority: WorkPriority, _ start: UInt64, _ end: UInt64) -> Void)? = nil,
         abandoned: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        self.id = id
        self.shutdown = shutdown
        self.trace = trace
        self.work = work
        self.ran = ran
        self.abandoned = abandoned
        self.done = done
    }

    /// Runs the body at `priority`, the level of the slot that runs it, unless the item was abandoned first, and
    /// returns its end: `clock` read once after the body, which `ran` gets with `start`. Nil when the item was
    /// abandoned and nothing ran.
    func execute(at priority: WorkPriority, startedAt start: UInt64, clock: () -> UInt64) -> UInt64? {
        guard claim() else { return nil }
        work(priority)
        let end = clock()
        ran?(priority, start, end)
        done()
        return end
    }

    /// Writes the flow-in of the item's post (when it was traced), right after its lane began the `task.run` slice.
    func traceArrival() {
        trace?.arrive()
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
