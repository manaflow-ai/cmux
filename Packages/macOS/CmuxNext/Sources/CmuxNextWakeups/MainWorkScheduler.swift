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

    /// Times the render pass after each frame's scheduled work while the link runs (nil in tests).
    private let renderPasses: RenderPassMeter?

    /// - Parameter budget: The app's budget (the app: ``SessionInputPending`` input and signposts on).
    ///   The render pass (layout, display, the Core Animation commit) is timed on the main run loop
    ///   while the link runs and charged to the next frame (``MainFrameBudget/noteRenderPass(nanos:)``).
    public convenience init(budget: MainFrameBudget) {
        let meter = RenderPassMeter { [weak budget] nanos in budget?.noteRenderPass(nanos: nanos) }
        self.init(budget: budget, frames: FrameScheduler(name: "budgeted", host: .screen, budget: budget), renderPasses: meter)
    }

    private init(budget: MainFrameBudget, frames: FrameScheduler, renderPasses: RenderPassMeter?) {
        self.budget = budget
        self.frames = frames
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
    ///   - makeLink: Makes the fake link.
    public static func testing(budget: MainFrameBudget = MainFrameBudget(), clock: any Clock<Duration> = ContinuousClock(),
                               ledger: WakeupLedger = .shared, makeLink: @escaping FrameScheduler.LinkFactory) -> MainWorkScheduler {
        MainWorkScheduler(budget: budget, frames: FrameScheduler(name: "budgeted test", host: .screen, clock: clock, ledger: ledger,
                                                                 makeLink: makeLink, budget: budget),
                          renderPasses: nil)
    }

    /// One display frame (the link's tick; tests call it directly).
    public func frameDidFire(timestamp: CFTimeInterval? = nil, refreshInterval: Double? = nil) {
        frames.frameDidFire(timestamp: timestamp, refreshInterval: refreshInterval)
    }
}
