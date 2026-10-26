public import CmuxNextControl
public import CmuxNextDaemon
public import CmuxNextWakeups

/// Runs main-actor batches once per display frame (architecture.md 2): the
/// daemon store drain, pane presentation, the control work queue, the
/// snapshot publisher and the invariant monitors each own one batcher.
///
/// A batcher is a ``FrameClient``: active only while work is pending, so an idle app has no
/// frame wakeups, and its scheduler's stall deadline keeps work moving while the displays sleep
/// (state-audit D4).
///
/// Each batcher runs through a ``FrameBatchQueue`` of a kind its owner picks: a frame batcher
/// (``init(owner:scheduler:)``: all of it every frame, for what a person's action caused) or a
/// budgeted one on the app's ``MainWorkScheduler`` (``init(owner:budgeted:on:)``: one task at a time
/// under the class's per-frame budget, yielding to a person's pending input, the rest on the next
/// frame). Every batcher names its scheduler: there is no default, so no batch runs outside the
/// budget's frame window (p06-scheduler-010).
///
/// A budgeted batcher's person items (``scheduleFrame(byPerson:_:)``) run unbudgeted on the
/// same scheduler's frame, ahead of its budgeted classes, as Blink runs the input-response frame's
/// work at input priority (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`,
/// `UseCase::kDiscreteInputResponse`).
@MainActor
public final class FrameBatcher: FrameBatchScheduler, ControlFrameSource {
    /// The queue that runs the batches (``FrameBatchQueue``, the one batch primitive).
    public let queue: FrameBatchQueue
    /// The batcher's priority class.
    public var workClass: MainWorkClass { queue.workClass }
    /// The board of the budget this batcher draws on (control requests intern their methods and
    /// count queued input there); nil for a frame batcher.
    public nonisolated let mainTaskBoard: MainTaskBoard?
    /// The budget this batcher's work draws on (the control work queue charges its requests to it);
    /// nil for a frame batcher.
    public let mainFrameBudget: MainFrameBudget?
    /// The scheduler a budgeted batcher's person items tick on (its ``MainWorkScheduler``'s frames);
    /// nil for a frame batcher, whose items all run unbudgeted already.
    private let personScheduler: FrameScheduler?
    /// The person items' frame queue, built on the first one.
    private var personQueue: FrameBatchQueue?

    /// A batcher of work a person's action caused: all of it every frame, unbudgeted.
    ///
    /// - Parameters:
    ///   - owner: Names the batcher in the wakeup ledger and debug.wakeups.
    ///   - scheduler: The frame scheduler: the app's ``MainWorkScheduler/frames``, or a window's.
    public init(owner: String, scheduler: FrameScheduler) {
        queue = FrameBatchQueue(owner: owner, scheduler: scheduler)
        mainTaskBoard = nil
        mainFrameBudget = nil
        personScheduler = nil
    }

    /// A batcher of budgeted work on the app's one main-thread scheduler.
    ///
    /// - Parameters:
    ///   - owner: Names the batcher in the wakeup ledger, debug.wakeups and the watchdog's records.
    ///   - budgeted: `visible` for screen updates no action of the person caused, `automation` for
    ///     control-socket work, `background` for work nobody sees this frame.
    ///   - work: The app's ``MainWorkScheduler`` (built at its composition root).
    public init(owner: String, budgeted: BudgetedWorkClass, on work: MainWorkScheduler) {
        queue = FrameBatchQueue(owner: owner, budgeted: budgeted, on: work)
        mainTaskBoard = work.budget.board
        mainFrameBudget = work.budget
        personScheduler = work.frames
    }

    /// Person work queued and not run yet (a budgeted batcher's person queue).
    public var personCount: Int { personQueue?.count ?? 0 }

    /// Queues `work` from main-actor code for the next display frame, by its cause: a person's work
    /// on a budgeted batcher runs unbudgeted in that frame (before the budgeted classes, never held
    /// by pending input or a spent share), the rest in the batcher's own queue.
    ///
    /// - Parameters:
    ///   - byPerson: A person's input caused `work` (the caller's ``MainFrameBudget`` input response
    ///     or the discrete input being dispatched).
    ///   - work: The batch.
    public func scheduleFrame(byPerson: Bool, _ work: @escaping @MainActor @Sendable () -> Void) {
        guard byPerson, let personScheduler else {
            queue.enqueue(work)
            return
        }
        let person = personQueue ?? FrameBatchQueue(owner: "\(queue.owner).person", scheduler: personScheduler)
        personQueue = person
        person.enqueue(work)
    }

    /// Hops through the main run loop in the common modes, not a main-actor
    /// task: a native menu tracks inside a main-queue callout, where no
    /// main-actor job runs until the menu closes (``MainRunLoopHop``).
    public nonisolated func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform { self.queue.enqueue(work) }
    }

    /// Appends `work` to the frame queue at once (main-actor callers, such as a budgeted drain that
    /// re-arms itself inside its tick): the queue's drain then reports work left, so its client
    /// stays active and the display link keeps running. Through ``scheduleFrame(_:)`` the hop
    /// landed after the tick, the queue went idle, and the link was invalidated and rebuilt (with
    /// its stall timer) every frame of a backlog.
    public func scheduleFrameFromMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        queue.enqueue(work)
    }

    /// The next main run loop turn, without waiting for a display frame
    /// (the control work queue's first request after idle).
    public nonisolated func scheduleSoon(_ work: @escaping @MainActor @Sendable () -> Void) {
        MainRunLoopHop().perform(work)
    }
}
