public import QuartzCore

/// The app's one main-thread scheduler for budgeted work (plans/cmux-next/main-thread-budget.md):
/// the per-frame ``MainFrameBudget`` and the scheduler its batches tick on, on the main display's
/// shared link (``DisplayClock``).
///
/// The app builds one at its composition root and passes it by init to everything that runs a
/// budgeted batch (the control work queue, the watchdog's board) and to the daemon services, whose
/// store drain is a frame client on its link (it ticks first, whole, every frame): there
/// is no shared instance. Budgeted clients exist only here (``FrameClient/init(owner:budgeted:on:onFrame:)``,
/// ``FrameBatchQueue/init(owner:budgeted:on:)``), so the budget's window opens once per real frame
/// on the main display's link, never once per tick of each display (two displays at 60 and 120 Hz
/// would otherwise roll it several times a frame). It ticks on that link only while one of its
/// clients has work or an input response waits for its tick; an idle app has no frame wakeups
/// from it. On each tick its frame-locked clients go first, then the window schedulers on that
/// display, then its budgeted classes.
///
/// Main-thread work that is not a batch is posted in a class with an owner
/// (``post(_:owner:file:line:_:)``, ``postFromAnyThread(_:owner:file:line:_:)``, ``apply(_:owner:file:line:_:)``,
/// and ``BackgroundWork/Pending/reply(on:class:owner:file:line:_:)`` for off-main work whose result
/// comes back): each class has one FIFO queue here, and the board names the posting site of the
/// task it runs.
///
/// It owns the app's ``StartupPhase``: while launching, background work (posts and budgeted
/// batches) waits in its queue for the reveal; input, frame, visible and automation work never
/// wait.
///
/// ```swift
/// // The composition root, with the app's one display clock:
/// let displays = DisplayClock()
/// FrameScheduler.install(displays: displays)
/// let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(), signposts: true),
///                                  displays: displays)
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
    /// The scheduler the budgeted clients tick on (on the main display); the daemon services'
    /// drains are frame clients on it, so they tick before the window schedulers and the budgeted classes.
    public let frames: FrameScheduler
    /// The launch's phases: which classes are held until the reveal or the settle.
    public let startup: StartupPhase

    /// Times the render pass after each frame's scheduled work while the link runs (nil in tests).
    private let renderPasses: RenderPassMeter?
    /// The posted work's class queues (MainWorkScheduler+Post.swift).
    var posting = Posting()
    /// Ticks the link while an input response is open (``MainFrameBudget/noteDiscreteInput(expectsFrame:)``
    /// asks for it), so the tick render that closes the response comes even while no budgeted
    /// client has work.
    private let inputResponseTick: FrameClient

    /// - Parameters:
    ///   - budget: The app's budget (the app: ``SessionInputPending`` input and signposts on).
    ///     The render pass (layout, display, the Core Animation commit) is timed on the main run loop
    ///     while it ticks and charged to the next frame (``MainFrameBudget/noteRenderPass(nanos:)``).
    ///   - displays: The composition root's display clock, which it shares with ``FrameScheduler/app``
    ///     and the windows (``FrameScheduler/install(displays:)``).
    ///   - startup: The launch's phases. The app's composition root passes a launching phase
    ///     (``StartupPhase/init(clock:ledger:timing:onHeldAwait:)``) with its reveal and references
    ///     wired; the default is settled, so a scheduler made after launch holds nothing.
    public convenience init(budget: MainFrameBudget, displays: DisplayClock, startup: StartupPhase = .settled()) {
        let meter = RenderPassMeter { [weak budget] nanos in budget?.noteRenderPass(nanos: nanos) }
        self.init(budget: budget, frames: FrameScheduler(name: "budgeted", host: .screen, displays: displays, budget: budget),
                  startup: startup, renderPasses: meter)
    }

    /// A scheduler on a display clock of its own (tests and fixtures; the app passes its one clock),
    /// so two of them never tick each other.
    public convenience init(budget: MainFrameBudget, startup: StartupPhase = .settled()) {
        self.init(budget: budget, displays: DisplayClock(), startup: startup)
    }

    private init(budget: MainFrameBudget, frames: FrameScheduler, startup: StartupPhase, renderPasses: RenderPassMeter?) {
        self.budget = budget
        board = budget.board
        self.frames = frames
        self.startup = startup
        self.renderPasses = renderPasses
        inputResponseTick = FrameClient(owner: "MainFrameBudget.inputResponse", isAnimation: false, on: frames) { [weak budget] _ in
            budget?.isInputResponseOpen ?? false
        }
        budget.requestTick = { [weak self] in self?.inputResponseTick.activate() }
        // Its display's ticks own the budget's window while it is subscribed; an idle app times no pass.
        frames.onLinkChange = { [weak self] exists in
            guard let self else { return }
            self.budget.tickOwnsWindow = exists
            if exists { self.renderPasses?.start() } else { self.renderPasses?.stop() }
        }
    }

    /// A scheduler on a fake link of its own display clock (tests): frames fire only through
    /// ``frameDidFire(timestamp:refreshInterval:targetTimestamp:)``,
    /// and render passes reach the budget only through ``renderPassEnded(nanos:)`` (or
    /// ``MainFrameBudget/noteRenderPass(nanos:)`` directly).
    ///
    /// - Parameters:
    ///   - budget: The budget (tests inject its clock and input source).
    ///   - clock: The stall deadline's clock.
    ///   - ledger: Where frames are recorded.
    ///   - startup: The launch's phases (default: already settled, so no class is held).
    ///   - makeLink: Makes the fake link.
    public static func testing(budget: MainFrameBudget = MainFrameBudget(), clock: any Clock<Duration> = ContinuousClock(),
                               ledger: WakeupLedger = .shared, startup: StartupPhase = .settled(),
                               makeLink: @escaping FrameScheduler.LinkFactory) -> MainWorkScheduler {
        MainWorkScheduler(budget: budget, frames: FrameScheduler.testing(name: "budgeted test", clock: clock, ledger: ledger,
                                                                         mediaTime: { CACurrentMediaTime() }, budget: budget,
                                                                         makeLink: makeLink),
                          startup: startup, renderPasses: nil)
    }

    /// A discrete input (a key-down, a mouse-down, `debug.key`) finished its dispatch; the App's
    /// `InputDispatchContext` calls it once per input. With `expectsFrame`, automation, background and
    /// idle work wait for the render pass of the link's next tick (``MainFrameBudget/noteDiscreteInput(expectsFrame:)``).
    ///
    /// - Parameter expectsFrame: The input's turn changed something the next frame shows.
    public func noteDiscreteInput(expectsFrame: Bool) {
        budget.noteDiscreteInput(expectsFrame: expectsFrame)
    }

    /// One render pass of the main run loop ended (the app's meter does the same; tests call it after
    /// ``frameDidFire(timestamp:refreshInterval:targetTimestamp:)``). It is charged to the next frame and
    /// ends the input response when a link tick began after the latest frame-expecting input
    /// (``MainFrameBudget/noteRenderPass(nanos:)``).
    ///
    /// - Parameter nanos: The pass's length.
    public func renderPassEnded(nanos: UInt64) {
        budget.noteRenderPass(nanos: nanos)
    }

    /// One display frame (tests call it directly; in the app the display's link ticks).
    /// `targetTimestamp`: when it is shown.
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil,
                             targetTimestamp: CFTimeInterval? = nil) {
        frames.frameDidFire(timestamp: timestamp, refreshInterval: refreshInterval, targetTimestamp: targetTimestamp)
    }
}
