import CmuxNextSignposts
public import QuartzCore

/// The rendering starvation guard of the main-thread scheduler (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, "Rendering starvation guard"): Chrome's `kRenderingStarved` in
/// third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc, with
/// `kDefaultRenderingStarvationThreshold` (100 ms) as ``threshold``.
///
/// Rendering is starved when a watched ``FrameScheduler`` (``watch(_:)``) has active frame clients
/// (``MainWorkClass/frame``: springs, autoscroll, the daemon drain), its display's link paces it
/// (not ``FrameScheduler/ticksOffLink``: a stopped link is a ``FrameStall``, not the main thread's
/// doing), its frames show (``RenderVisibility``: not occluded, not miniaturized, displays awake),
/// and its last tick is more than ``threshold`` plus one refresh period old. The extra period is the
/// stall deadline's: it is due at ``threshold`` and, on an idle main thread, runs within a frame, so
/// a tick later than that was held by the main thread.
///
/// Chrome then puts the compositor queue above everything but input; cmux's frame is the link tick,
/// which no queue holds, so the equivalent is to hold what the scheduler controls until that link's
/// next tick. Input and frame work never wait. While starved:
/// - ``MainFrameBudget/mayRun(_:)`` refuses every budgeted class. That holds everything posted
///   (``MainWorkScheduler/post(_:owner:file:line:_:)``) and every ``FrameBatchQueue``, so also the
///   deadlines MainDeadline runs through post (p06-scheduler task 011) and the drain's automation
///   tail, a budgeted queue (task 223).
/// - A CEF pump made with the guard runs one slice per late frame (``admitsSlice(_:)``) and the next
///   after the late link ticks (``afterLateFrame(_:)``). `CEFRuntime` makes its pump without one,
///   also on the main-thread board (task 048): a late frame must not slow a hidden tab's CDP round trip.
/// - Idle periods (IdleScheduler, task 005) start only when ``MainFrameBudget/isRenderStarved`` is
///   false; that task adds the read.
///
/// Each late period reports once, `stall.render_starved` with the turn meter's top unattributed
/// turn over the late interval (``UnattributedTurnSource``): at the first check that sees it, else at
/// the late tick itself, so a period with no work waiting reports too. The stall deadline is the
/// check timer: an unposted ``DemandTimer`` each display arms at ``threshold`` while it has
/// subscribers, never queued behind the classes it measures.
///
/// ```swift
/// // After FrameScheduler.install(displays:energy:): the window schedulers made later are watched with the app's.
/// let starvation = RenderStarvationGuard(holdsWork: features.isEnabled(.renderStarvationGuard), signposts: true)
/// let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(events: WindowServerInputEvents(input: inputTap)), signposts: true,
///                                                          starvation: starvation), displays: displays, wakeUps: mainWakeUps)
/// starvation.watch(mainWork.frames, FrameScheduler.app)
/// ```
@MainActor
public final class RenderStarvationGuard {
    /// Chrome's `kDefaultRenderingStarvationThreshold`.
    public static let threshold: CFTimeInterval = 0.1

    /// Counters for `debug.main_budget` (``MainFrameBudget/report``) and the benches.
    public struct Stats: Sendable, Equatable {
        /// Late periods reported (`stall.render_starved`).
        public var events = 0
        /// Per budgeted class (``MainFrameBudget/Stats/classes`` order): times a task was held for a late frame.
        public var heldTasks: [Int] = [0, 0, 0, 0]
        /// Slices of a source outside the budget (the CEF pump) held for a late frame.
        public var heldSlices = 0
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

    /// What a source outside the budget last ran in (``admitsSlice(_:)``).
    public struct Slices: Sendable, Equatable {
        /// The late frame (its scheduler's last tick) the source last ran a slice in.
        fileprivate var lateFrame: CFTimeInterval?

        /// A source that ran no slice yet.
        public init() {}
    }

    /// Whether a starvation holds work (feature `renderStarvationGuard`). Off, the guard only
    /// reports. The composition root sets it once its feature list is built.
    public var holdsWork: Bool
    /// What the guard saw and held since it was made (`debug.main_budget`, tests).
    public private(set) var stats = Stats()
    /// The last starvation reported (debug and tests).
    public private(set) var last: RenderStarvation?

    private var watched: [WeakScheduler] = []
    private let visibility: any RenderVisibility
    private let turns: (any UnattributedTurnSource)?
    private let mediaTime: @MainActor () -> CFTimeInterval
    private let signposts: Bool
    /// No watched link can be late before this time: until then a check reads no link.
    private var nextScan: CFTimeInterval = 0
    /// The oldest last tick of the late shown links at the last check (nil: not starved).
    private var lateFrame: CFTimeInterval?
    /// What waits for a late link's next tick (``afterLateFrame(_:)``).
    private var resumes: [@MainActor () -> Void] = []

    /// - Parameters:
    ///   - holdsWork: Whether a starvation holds work, or is only reported.
    ///   - visibility: Whether a scheduler's frames show (the app: ``AppKitRenderVisibility``).
    ///   - turns: The turn meter that names the job to blame; nil reports none.
    ///   - signposts: Whether a starvation emits `stall.render_starved`.
    ///   - mediaTime: The schedulers' clock (``DisplayClock/now()``, `CACurrentMediaTime`); tests inject theirs.
    public init(holdsWork: Bool, visibility: any RenderVisibility = AppKitRenderVisibility(), turns: (any UnattributedTurnSource)? = nil,
                signposts: Bool = false, mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.holdsWork = holdsWork
        self.visibility = visibility
        self.turns = turns
        self.signposts = signposts
        self.mediaTime = mediaTime
    }

    /// Watches the frames of `schedulers`. The schedulers ``FrameScheduler/forWindow(_:)`` makes while
    /// ``FrameScheduler/app`` is watched are watched by the same guard.
    public func watch(_ schedulers: FrameScheduler...) {
        watched.removeAll { $0.value == nil }
        for scheduler in schedulers where scheduler.starvation !== self {
            scheduler.starvation = self
            watched.append(WeakScheduler(value: scheduler))
        }
        nextScan = 0
    }

    /// Whether a shown link with active frame clients is late now. Reports a late period the first
    /// time it is seen, whether or not the guard holds work.
    public func isStarved() -> Bool { // perf-hot: 0.5ms frame-tick (before every budgeted task)
        let now = mediaTime()
        if now < nextScan { return false }
        var oldest: CFTimeInterval?
        var next = now + Self.threshold
        for entry in watched {
            guard let link = entry.value, link.hasActiveFrameClients, !link.ticksOffLink else { continue }
            let deadline = link.lastTick + Self.lateAfter(link)
            if now <= deadline {
                next = min(next, deadline)
                continue
            }
            if period(of: link, endingAt: now).shows { oldest = min(oldest ?? link.lastTick, link.lastTick) }
        }
        lateFrame = oldest
        // While starved every check scans: the period ends at the late link's next tick.
        nextScan = oldest == nil ? next : now
        return oldest != nil
    }

    /// Whether a source outside the budget may run a slice now: always, unless a late frame holds
    /// work and the source already ran one since that frame's link last ticked (the CEF pump's one
    /// slice per frame). A held source waits for ``afterLateFrame(_:)``.
    public func admitsSlice(_ slices: inout Slices) -> Bool {
        guard isStarved(), holdsWork, let lateFrame else { return true }
        guard slices.lateFrame != lateFrame else {
            stats.heldSlices += 1
            return false
        }
        slices.lateFrame = lateFrame
        return true
    }

    /// Calls `resume` once, at the next tick of a watched link (or when one stops ticking): a source
    /// the guard held runs again then. It runs inside that tick, so it only re-arms its own wake.
    public func afterLateFrame(_ resume: @escaping @MainActor () -> Void) {
        resumes.append(resume)
    }

    /// `link` ticks at `now`, before its ``FrameScheduler/lastTick`` moves: a late period this tick
    /// ends that no check saw reports here, then what waited for a late frame goes on.
    func tickEnds(_ link: FrameScheduler, at now: CFTimeInterval) { // perf-hot: 0.5ms frame-tick (every frame)
        if now - link.lastTick > Self.lateAfter(link), !link.ticksOffLink, link.hasActiveFrameClients {
            _ = period(of: link, endingAt: now)
        }
        framesEnded(link)
    }

    /// `link` ticked or left its display: what waited for a late frame goes on.
    func framesEnded(_ link: FrameScheduler) {
        guard !resumes.isEmpty else { return }
        let due = resumes
        resumes.removeAll()
        for resume in due { resume() }
    }

    /// Counts one task of the budgeted class at `index` held for a late frame.
    func noteHeld(_ index: Int) {
        stats.heldTasks[index] += 1
    }

    /// Clears the counters (`debug.main_budget reset`).
    public func resetStats() {
        stats = Stats()
    }

    /// How old `link`'s last tick may get before it is late: ``threshold`` and one of its frames.
    private static func lateAfter(_ link: FrameScheduler) -> CFTimeInterval {
        threshold + link.refreshPeriod
    }

    /// `link`'s late period since its last tick, seen first now: visibility is asked once, and a shown
    /// one is reported.
    private func period(of link: FrameScheduler, endingAt now: CFTimeInterval) -> Period {
        if let period = link.starvationPeriod, period.lastTick == link.lastTick { return period }
        let period = Period(lastTick: link.lastTick, shows: visibility.showsFrames(of: link))
        link.starvationPeriod = period
        if period.shows { report(link, at: now) }
        return period
    }

    private func report(_ link: FrameScheduler, at now: CFTimeInterval) {
        let since = UInt64(max(link.lastTick, 0) * 1_000_000_000)
        let starvation = RenderStarvation(link: link.name, lastTick: link.lastTick, detectedAt: now,
                                          turn: turns?.topUnattributedTurn(endingAfter: since))
        last = starvation
        stats.events += 1
        stats.maxGap = max(stats.maxGap, now - link.lastTick)
        if signposts { Signposter.stall.event(.stallRenderStarved, starvation.message) }
    }

    private struct WeakScheduler {
        weak var value: FrameScheduler?
    }
}
