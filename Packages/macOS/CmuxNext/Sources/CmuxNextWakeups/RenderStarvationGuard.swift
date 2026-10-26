import CmuxNextSignposts
public import QuartzCore

/// The rendering starvation guard of the main-thread scheduler (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, "Rendering starvation guard"): Chrome's `kRenderingStarved` in
/// third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc, with
/// `kDefaultRenderingStarvationThreshold` (100 ms) as ``threshold``.
///
/// Rendering is starved when a watched ``FrameScheduler`` has active frame clients
/// (``MainWorkClass/frame``: springs, autoscroll, the daemon drain), its frames show
/// (``RenderVisibility``: not occluded, not miniaturized, displays awake), and its last tick is
/// more than ``threshold`` old. Chrome then puts the compositor queue above everything but input;
/// cmux's frame is the link tick, which no queue holds, so the equivalent is to hold everything
/// else the scheduler controls until that link's next tick (a display frame, or the scheduler's
/// stall tick). ``MainFrameBudget/mayRun(_:)`` refuses every budgeted class, and the sources
/// outside the budget (idle periods, CEF pump slices past one per frame, posted deadlines, the
/// drain's automation tail) read ``MainFrameBudget/isRenderStarved``. Input and frame work never wait.
///
/// Each late period reports once: `stall.render_starved` with the turn meter's top unattributed
/// turn since the link's last tick (``UnattributedTurnSource``), the main-thread job that kept the
/// frame from running.
///
/// ```swift
/// let starvation = RenderStarvationGuard(holdsWork: features.isEnabled(.renderStarvationGuard),
///                                        links: { [frames = mainWork.frames] in [frames] + FrameScheduler.all },
///                                        turns: turnMeter, signposts: true)
/// let budget = MainFrameBudget(input: SessionInputPending(), signposts: true, starvation: starvation)
/// ```
@MainActor
public final class RenderStarvationGuard {
    /// Chrome's `kDefaultRenderingStarvationThreshold`: a link whose last tick is older is late.
    public static let threshold: CFTimeInterval = 0.1

    /// Counters for `debug.main_budget` and the benches.
    public struct Stats: Sendable, Equatable {
        /// Late periods reported (`stall.render_starved`).
        public var events = 0
        /// Per budgeted class (``MainWorkClass/budgeted`` order): times a task was held for a late frame.
        public var heldTasks: [Int] = [0, 0, 0]
        /// The longest gap a period had when it was reported, in seconds.
        public var maxGap: CFTimeInterval = 0
    }

    /// One late period of one scheduler, kept on it until its next tick.
    struct Period {
        /// The tick the period follows.
        let lastTick: CFTimeInterval
        /// Whether the scheduler's frames show (asked once per period).
        let shows: Bool
    }

    /// Whether a starvation holds work (feature `renderStarvationGuard`). Off, the guard only reports.
    public let holdsWork: Bool
    public private(set) var stats = Stats()
    /// The last starvation reported (debug and tests).
    public private(set) var last: RenderStarvation?

    private let links: @MainActor () -> [FrameScheduler]
    private let visibility: any RenderVisibility
    private let turns: (any UnattributedTurnSource)?
    private let mediaTime: @MainActor () -> CFTimeInterval
    private let signposts: Bool
    /// No watched link can be late before this time: until then a check reads no link.
    private var nextScan: CFTimeInterval = 0

    /// - Parameters:
    ///   - holdsWork: Whether a starvation holds work, or is only reported.
    ///   - links: Every watched frame scheduler: the ``MainWorkScheduler``'s and ``FrameScheduler/all``.
    ///     Read at most once per ``threshold`` while no link is late.
    ///   - visibility: Whether a scheduler's frames show (the app: ``AppKitRenderVisibility``).
    ///   - turns: The turn meter that names the job to blame; nil reports none.
    ///   - signposts: Whether a starvation emits `stall.render_starved`.
    ///   - mediaTime: The clock of the schedulers' ticks (`CACurrentMediaTime`); tests inject theirs.
    public init(holdsWork: Bool, links: @escaping @MainActor () -> [FrameScheduler],
                visibility: any RenderVisibility = AppKitRenderVisibility(), turns: (any UnattributedTurnSource)? = nil,
                signposts: Bool = false, mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.holdsWork = holdsWork
        self.links = links
        self.visibility = visibility
        self.turns = turns
        self.signposts = signposts
        self.mediaTime = mediaTime
    }

    /// Whether a shown link with active frame clients is late now. Reports a late period the first
    /// time it is seen, whether or not the guard holds work.
    public func isStarved() -> Bool { // perf-hot: 0.5ms frame-tick (before every budgeted task)
        let now = mediaTime()
        if now < nextScan { return false }
        var starved = false
        var next = now + Self.threshold
        for link in links() where link.hasActiveFrameClients {
            let deadline = link.lastTick + Self.threshold
            if now <= deadline {
                next = min(next, deadline)
                continue
            }
            if link.starvationPeriod?.lastTick != link.lastTick {
                let shows = visibility.showsFrames(of: link)
                link.starvationPeriod = Period(lastTick: link.lastTick, shows: shows)
                if shows { report(link, at: now) }
            }
            if link.starvationPeriod?.shows == true { starved = true }
        }
        // While starved every check scans: the period ends at the late link's next tick.
        nextScan = starved ? now : next
        return starved
    }

    /// Counts one task of the budgeted class at `index` held for a late frame.
    func noteHeld(_ index: Int) {
        stats.heldTasks[index] += 1
    }

    /// Clears the counters (`debug.main_budget reset`).
    public func resetStats() {
        stats = Stats()
    }

    private func report(_ link: FrameScheduler, at now: CFTimeInterval) {
        let since = UInt64(max(link.lastTick, 0) * 1_000_000_000)
        let starvation = RenderStarvation(link: link.name, lastTick: link.lastTick, detectedAt: now,
                                          turn: turns?.topUnattributedTurn(since: since))
        last = starvation
        stats.events += 1
        stats.maxGap = max(stats.maxGap, now - link.lastTick)
        if signposts { Signposter.stall.event(.stallRenderStarved, starvation.message) }
    }
}
