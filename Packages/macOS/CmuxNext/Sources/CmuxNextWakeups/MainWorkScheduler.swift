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
/// It owns the app's ``StartupPhase``: while launching, background and idle posts wait for the
/// phase that opens them (``StartupPhase/whenReached(_:_:)``); input, frame, visible and
/// automation work never wait.
///
/// ```swift
/// // The composition root:
/// let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(), signposts: true))
/// let requests = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: mainWork)
///
/// // A test drives the frames by hand:
/// let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in FakeLink() }
/// work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
/// ```
@MainActor
public final class MainWorkScheduler {
    /// The per-frame budget every budgeted batch draws on.
    public let budget: MainFrameBudget
    /// The display-link scheduler the budgeted clients tick on (the main screen's); the daemon
    /// services' drains are frame clients on it, so they tick before the budgeted classes.
    public let frames: FrameScheduler
    /// The launch's phases: which classes are held until the reveal or the settle.
    public let startup: StartupPhase

    /// Times the render pass after each frame's scheduled work while the link runs (nil in tests).
    private let renderPasses: RenderPassMeter?

    /// - Parameters:
    ///   - budget: The app's budget (the app: ``SessionInputPending`` input and signposts on).
    ///     The render pass (layout, display, the Core Animation commit) is timed on the main run loop
    ///     while the link runs and charged to the next frame (``MainFrameBudget/noteRenderPass(nanos:)``).
    ///   - startup: The launch's phases; the default is a launching phase whose reveal deadline
    ///     starts now (the composition root builds the scheduler at launch).
    public convenience init(budget: MainFrameBudget, startup: StartupPhase = StartupPhase()) {
        let meter = RenderPassMeter { [weak budget] nanos in budget?.noteRenderPass(nanos: nanos) }
        self.init(budget: budget, frames: FrameScheduler(name: "budgeted", host: .screen, budget: budget), startup: startup,
                  renderPasses: meter)
    }

    private init(budget: MainFrameBudget, frames: FrameScheduler, startup: StartupPhase, renderPasses: RenderPassMeter?) {
        self.budget = budget
        self.frames = frames
        self.startup = startup
        self.renderPasses = renderPasses
        // The link's ticks own the budget's window while it exists; an idle app times no pass.
        frames.onLinkChange = { [weak self] exists in
            guard let self else { return }
            self.budget.tickOwnsWindow = exists
            if exists { self.renderPasses?.start() } else { self.renderPasses?.stop() }
        }
    }

    /// A scheduler on a fake link (tests): frames fire only through ``frameDidFire(timestamp:refreshInterval:)``,
    /// and render passes reach the budget only through ``MainFrameBudget/noteRenderPass(nanos:)``.
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
        MainWorkScheduler(budget: budget, frames: FrameScheduler(name: "budgeted test", host: .screen, clock: clock, ledger: ledger,
                                                                 makeLink: makeLink, budget: budget),
                          startup: startup, renderPasses: nil)
    }

    /// Runs `enqueue` now when startup admits `workClass`, else at the phase change that opens it,
    /// after the enqueues held before it: the hold every `post` of a class takes, so held bodies
    /// reach their class queue in post order. Input, frame, visible and automation never wait.
    public func whenStartupAdmits(_ workClass: MainWorkClass, _ enqueue: @escaping @MainActor () -> Void) {
        startup.whenReached(workClass.startupOpening, enqueue)
    }

    /// Runs `enqueue` now when startup has settled, else at the settle: the hold of idle posts.
    public func whenStartupAdmitsIdle(_ enqueue: @escaping @MainActor () -> Void) {
        startup.whenReached(.settled, enqueue)
    }

    /// One display frame (the link's tick; tests call it directly).
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil) {
        frames.frameDidFire(timestamp: timestamp, refreshInterval: refreshInterval)
    }
}
