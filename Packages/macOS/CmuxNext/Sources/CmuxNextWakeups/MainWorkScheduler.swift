public import QuartzCore

/// The app's one main-thread scheduler for budgeted work (plans/cmux-next/main-thread-budget.md):
/// the per-frame ``MainFrameBudget`` and the one display link its batches tick on.
///
/// The app builds one at its composition root and passes it by init to everything that runs a
/// budgeted batch (the control work queue, the watchdog's board) and to the daemon services, whose
/// store drain is a frame client on its link (it ticks first, whole, every frame): there
/// is no shared instance. Budgeted clients exist only here (``FrameClient/init(owner:budgeted:on:onFrame:)``,
/// ``FrameBatchQueue/init(owner:budgeted:on:)``), so the budget's window opens once per real frame
/// on this one link, never once per tick of each window's link (two displays at 60 and 120 Hz
/// would otherwise roll it several times a frame). Its link exists only while one of its clients
/// has work; an idle app has no frame wakeups from it.
///
/// Main-thread work that is not a batch is posted in a class with an owner
/// (``post(_:owner:file:line:_:)``, ``postFromAnyThread(_:owner:file:line:_:)``, ``apply(_:owner:file:line:_:)``,
/// and ``BackgroundWork/Pending/reply(on:class:owner:file:line:_:)`` for off-main work whose result
/// comes back): each class has one FIFO queue here, and the board names the posting site of the
/// task it runs.
///
/// Idle work (``MainWorkClass/idle``) is posted with ``postIdle(owner:maxDelay:node:file:line:_:)``
/// and runs in the ``idle`` scheduler's idle periods, each task with a deadline.
///
/// ```swift
/// // The composition root:
/// let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(), signposts: true))
/// let requests = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: mainWork)
/// mainWork.post(.automation, owner: "browser-host.open") { host.open(url) }
///
/// // A test drives the frames by hand:
/// let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in FakeLink() }
/// work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
/// ```
@MainActor
public final class MainWorkScheduler {
    /// The per-frame budget every budgeted batch draws on.
    public let budget: MainFrameBudget
    /// The budget's board, readable from any thread (``postFromAnyThread(_:owner:file:line:_:)``
    /// interns owners on it off the main thread).
    public nonisolated let board: MainTaskBoard
    /// The display-link scheduler the budgeted clients tick on (the main screen's); the daemon
    /// services' drains are frame clients on it, so they tick before the budgeted classes.
    public let frames: FrameScheduler
    /// The idle class's periods and queue (``postIdle(owner:maxDelay:node:file:line:_:)``).
    public let idle: IdleScheduler

    /// Times the render pass after each frame's scheduled work while the link runs (nil in tests).
    private var renderPasses: RenderPassMeter?
    /// The next vsync after the last link frame (`CLOCK_UPTIME_RAW` nanoseconds), until that
    /// frame's render pass ends: a short idle period may run before it.
    private var nextVsyncNanos: UInt64?
    /// The posted work's class queues (MainWorkScheduler+Post.swift).
    var posting = Posting()

    /// - Parameter budget: The app's budget (the app: ``SessionInputPending`` input and signposts on).
    ///   The render pass (layout, display, the Core Animation commit) is timed on the main run loop
    ///   while the link runs and charged to the next frame (``MainFrameBudget/noteRenderPass(nanos:)``).
    ///   Idle periods use an unposted precise run-loop timer; a long one waits until no scheduler's
    ///   display link runs (``FrameScheduler/all``).
    public convenience init(budget: MainFrameBudget) {
        self.init(budget: budget, frames: FrameScheduler(name: "budgeted", host: .screen, budget: budget),
                  idleTimer: MainRunLoopPreciseTimer(), ledger: .shared,
                  otherFramesActive: { FrameScheduler.all.contains { $0.hasLink } }, measuresRenderPasses: true)
    }

    private init(budget: MainFrameBudget, frames: FrameScheduler, idleTimer: any IdlePeriodTimer, ledger: WakeupLedger,
                 otherFramesActive: @escaping @MainActor () -> Bool, measuresRenderPasses: Bool) {
        self.budget = budget
        board = budget.board
        self.frames = frames
        idle = IdleScheduler(budget: budget, timer: idleTimer, ledger: ledger, otherFramesActive: otherFramesActive)
        if measuresRenderPasses {
            renderPasses = RenderPassMeter { [weak self] nanos in self?.renderPassEnded(nanos: nanos) }
        }
        // The link's ticks own the budget's window while it exists; an idle app times no pass.
        frames.onLinkChange = { [weak self] exists in
            guard let self else { return }
            self.budget.tickOwnsWindow = exists
            if exists {
                self.renderPasses?.start()
            } else {
                self.renderPasses?.stop()
                self.nextVsyncNanos = nil
            }
            self.idle.framesChanged(running: exists)
        }
        frames.onLinkFrame = { [weak self] timestamp, refreshInterval in
            // CACurrentMediaTime's timebase is CLOCK_UPTIME_RAW's, in seconds.
            self?.nextVsyncNanos = UInt64(max(0, timestamp + refreshInterval) * 1_000_000_000)
        }
        idle.promote = { [weak self] owner, site, body in self?.post(.background, owner: owner, site: site, body) }
    }

    /// A scheduler on a fake link (tests): frames fire only through ``frameDidFire(timestamp:refreshInterval:)``,
    /// and render passes reach the budget and the idle scheduler only through ``renderPassEnded(nanos:)``.
    ///
    /// - Parameters:
    ///   - budget: The budget (tests inject its clock and input source).
    ///   - clock: The stall deadline's clock.
    ///   - ledger: Where frames and idle period timer fires are recorded.
    ///   - idleTimer: The idle period timer (tests: a fake fired by hand).
    ///   - otherFramesActive: Whether a frame client ticks on another scheduler (holds long idle periods).
    ///   - makeLink: Makes the fake link.
    public static func testing(budget: MainFrameBudget = MainFrameBudget(), clock: any Clock<Duration> = ContinuousClock(),
                               ledger: WakeupLedger = .shared, idleTimer: any IdlePeriodTimer = MainRunLoopPreciseTimer(),
                               otherFramesActive: @escaping @MainActor () -> Bool = { false },
                               makeLink: @escaping FrameScheduler.LinkFactory) -> MainWorkScheduler {
        MainWorkScheduler(budget: budget, frames: FrameScheduler(name: "budgeted test", host: .screen, clock: clock, ledger: ledger,
                                                                 makeLink: makeLink, budget: budget),
                          idleTimer: idleTimer, ledger: ledger, otherFramesActive: otherFramesActive, measuresRenderPasses: false)
    }

    /// One display frame (the link's tick; tests call it directly).
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil) {
        frames.frameDidFire(timestamp: timestamp, refreshInterval: refreshInterval)
    }

    /// One render pass of the main run loop ended (the ``RenderPassMeter``; tests call it after a
    /// frame): it is charged to the next frame's budget, and when it followed a link frame, a short
    /// idle period may run until 1 ms before the next vsync.
    ///
    /// - Parameter nanos: The pass's length.
    public func renderPassEnded(nanos: UInt64) {
        budget.noteRenderPass(nanos: nanos)
        guard let vsync = nextVsyncNanos else { return }
        nextVsyncNanos = nil
        idle.frameRendered(nextVsyncNanos: vsync, budgetedWorkHeld: frames.hasBudgetedWork)
    }

    /// Queues `body` for the main thread's idle time (``MainWorkClass/idle``): a long idle period
    /// after 50 ms of quiet, or a short one between a frame's render pass and the next vsync. It
    /// gets the period's ``IdleDeadline``; pending input ends the period, and a task posted from an
    /// idle task waits for the next one. Never inline.
    ///
    /// - Parameters:
    ///   - owner: The task's owner in the board, the watchdog's records and signposts.
    ///   - maxDelay: When set, a task that has not run by then runs as ``MainWorkClass/background``
    ///     work with ``IdleDeadline/didTimeout`` set. Nil (the default): it waits for idle time.
    ///   - node: The node of the thing the task is for: its periods stop 10 s after the node is
    ///     hidden and resume on show; the task is dropped when the node is released.
    ///   - file: The posting file (leave the default).
    ///   - line: The posting line (leave the default).
    ///   - body: The task.
    public func postIdle(owner: String, maxDelay: Duration? = nil, node: VisibilityNode? = nil, file: StaticString = #fileID,
                         line: UInt = #line, _ body: @escaping @MainActor (IdleDeadline) -> Void) {
        idle.post(owner: taskOwner(owner), site: MainPostSite(file: file, line: line), maxDelay: maxDelay, node: node, body)
    }

    /// ``postIdle(owner:maxDelay:node:file:line:_:)`` with an owner already interned on this
    /// scheduler's board (``MainTaskBoard/owner(_:)``).
    public func postIdle(owner: MainTaskOwner, maxDelay: Duration? = nil, node: VisibilityNode? = nil, file: StaticString = #fileID,
                         line: UInt = #line, _ body: @escaping @MainActor (IdleDeadline) -> Void) {
        idle.post(owner: owner, site: MainPostSite(file: file, line: line), maxDelay: maxDelay, node: node, body)
    }
}
