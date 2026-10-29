public import AppKit
import CmuxNextWakeups
import Observation
public import CmuxNextDesignTokens

/// Launch load-in, region by region: a view held for a region stays clear
/// on the window glass until that region's data is ready, then fades in
/// (`MotionFade.fadeIn`; capped under Reduce Motion), independently of the
/// other regions, never all at once. A view held after its region is
/// ready, or ready before the window first drew it, shows at once, so a
/// fast launch or a relaunch with saved data adds no fade and no delay.
///
/// Producers call `markReady` where the data lands (the sidebar's first
/// rows, the first non-empty tab strip, the first terminal frame); a
/// launch that cannot produce a region (daemon unavailable) calls
/// `markAllReady`. A region whose data never arrives (no tabs, a pane
/// that never draws) is released by the deadline, which the first `hold`
/// arms (a region made after the window: its own first hold): a missed
/// producer costs a short delay, never a blank window.
///
/// Call `markReady` where real data lands, not on an empty placeholder
/// model (unless nothing is coming before the first frame: a fresh
/// profile's sidebar has no saved rows to wait for), and hold containers,
/// not views that animate their own alpha.
/// The regions are app-wide and cover the first launch: once a region is
/// ready, windows opened later show it at once. The app makes one at its
/// composition root (`AppDelegate`) and passes it by init; there is no
/// shared instance.
///
/// A region under the window's saved picture (`LaunchPicturePhase`)
/// needs no fade of its own: its views show at once under
/// the picture, and the picture's part over the region is what fades, at the
/// region's first content.
@MainActor
@Observable
public final class LaunchReveal {
    /// Regions whose data has arrived. Only grows.
    public private(set) var ready: Set<LaunchRegion> = []
    @ObservationIgnored private var held: [LaunchRegion: NSHashTable<NSView>] = [:]
    @ObservationIgnored private var waiters: [LaunchRegion: [@MainActor () -> Void]] = [:]
    /// Regions whose producer called `markReady` (or `markAllReady`); the deadline shows a region
    /// without adding it here, so its data landing later still counts for `onRevealed`.
    @ObservationIgnored private var produced: Set<LaunchRegion> = []
    @ObservationIgnored private var producedWaiters: [LaunchRegion: [@MainActor () -> Void]] = [:]
    /// Regions under the launch picture, by the number of covers over them (``coverBegan(_:)``).
    @ObservationIgnored private var covered: [LaunchRegion: Int] = [:]
    @ObservationIgnored private var reportedReveal = false
    @ObservationIgnored private let deadlineTimer: DemandTimer
    /// The deadlines of regions made after the window (`LaunchRegion.hasOwnDeadline`).
    @ObservationIgnored private var ownDeadlines: [LaunchRegion: DemandTimer] = [:]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let deadline: Duration
    @ObservationIgnored private let onRevealed: @MainActor () -> Void

    /// - Parameters:
    ///   - deadline: How long after the first `hold` every region shows anyway.
    ///   - onRevealed: Runs once, in the turn the last region's producer marked it ready (its data
    ///     landed, or `markAllReady`: none will come): the launch window shows its content. The
    ///     deadline does not run it, since it shows regions with no data; a region marked after
    ///     the deadline still counts. The app ends its startup phase's `launching` here
    ///     (`StartupPhase.noteFirstFrame()`), as Chrome's first paint does
    ///     (`chrome/browser/after_startup_task_utils.cc`).
    public init(clock: any Clock<Duration> = ContinuousClock(), deadline: Duration = .milliseconds(1500),
                onRevealed: @escaping @MainActor () -> Void = {}) {
        // timer-class-allow: the launch's one failsafe on the injected clock, made in AppDelegate before the app's deadline scheduler exists; it fires at most once
        deadlineTimer = DemandTimer(owner: "launch.reveal-deadline", clock: clock)
        self.clock = clock
        self.deadline = deadline
        self.onRevealed = onRevealed
    }

    /// Whether every region is ready: the launch is revealed.
    public var isRevealed: Bool { ready.count == LaunchRegion.allCases.count }

    public func isReady(_ region: LaunchRegion) -> Bool { ready.contains(region) }

    /// Keeps `view` clear until `region` is ready (a no-op once it is).
    public func hold(_ view: NSView, until region: LaunchRegion) {
        guard !isReady(region) else { return }
        view.alphaValue = 0
        // NSHashTable is a class: insert the table first, since `add` through
        // a defaulted subscript would go to a temporary.
        let table = held[region] ?? NSHashTable<NSView>.weakObjects()
        held[region] = table
        // Held alone (the views held before it went away): a region with its own deadline waits from here.
        let alone = table.allObjects.allSatisfy { $0 === view }
        table.add(view)
        // The deadline shows a region without counting it as produced (`showAll`); a region made after the
        // window (`LaunchRegion.hasOwnDeadline`) waits from its own first hold.
        guard region.hasOwnDeadline else {
            deadlineTimer.scheduleOnMainIfIdle(after: deadline) { [weak self] in
                for region in LaunchRegion.allCases where !region.hasOwnDeadline { self?.show(region) }
            }
            return
        }
        // timer-class-allow: a region made after the window has one failsafe on the injected clock, as the launch's; it fires at most once per hold
        let timer = ownDeadlines[region] ?? DemandTimer(owner: "launch.reveal-deadline.\(region.rawValue)", clock: clock)
        ownDeadlines[region] = timer
        if alone {
            timer.scheduleOnMain(after: deadline) { [weak self] in self?.show(region) }
        } else {
            timer.scheduleOnMainIfIdle(after: deadline) { [weak self] in self?.show(region) }
        }
    }

    /// Runs `work` once `region` is ready (at once when it is).
    public func whenReady(_ region: LaunchRegion, _ work: @escaping @MainActor () -> Void) {
        if isReady(region) { work() } else { waiters[region, default: []].append(work) }
    }

    /// Whether `region`'s producer marked it: its data landed (the deadline does not count).
    public func isProduced(_ region: LaunchRegion) -> Bool { produced.contains(region) }

    /// Runs `work` once `region`'s data landed (``markReady(_:)``, at once when it has); the deadline does not run it.
    public func whenProduced(_ region: LaunchRegion, _ work: @escaping @MainActor () -> Void) {
        if isProduced(region) { work() } else { producedWaiters[region, default: []].append(work) }
    }

    /// `region`'s data arrived: its held views fade in. Later calls do nothing.
    public func markReady(_ region: LaunchRegion) {
        let first = produced.insert(region).inserted
        show(region)
        if first { for work in producedWaiters.removeValue(forKey: region) ?? [] { work() } }
        guard !reportedReveal, produced.count == LaunchRegion.allCases.count else { return }
        reportedReveal = true
        deadlineTimer.cancel()
        for timer in ownDeadlines.values { timer.cancel() }
        onRevealed()
    }

    /// `region` shows: its held views fade in and its waiters run (first call only).
    private func show(_ region: LaunchRegion) {
        guard ready.insert(region).inserted else { return }
        let views = held.removeValue(forKey: region)?.allObjects ?? []
        for view in views {
            // The model value at once; the fade runs on the layer.
            view.alphaValue = 1
            // A view whose window has not drawn it yet (no presentation layer: a relaunch's saved
            // tabs before the first frame) shows in its first frame, not faded in from clear. Under a saved picture
            // it shows at once too: the picture's part over it fades instead (a second fade would show the glass).
            if covered[region, default: 0] == 0, let layer = view.layer, layer.presentation() != nil {
                Motion.panes.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
            }
        }
        for work in waiters.removeValue(forKey: region) ?? [] { work() }
        if isRevealed {
            deadlineTimer.cancel()
            for timer in ownDeadlines.values { timer.cancel() }
        }
    }

    /// Every region shows (the hold deadline, a picture's bound), without counting as produced.
    public func showAll() {
        for region in LaunchRegion.allCases { show(region) }
    }

    /// The launch picture now lies over `regions`: their views show with no fade of their own.
    public func coverBegan(_ regions: Set<LaunchRegion>) {
        for region in regions { covered[region, default: 0] += 1 }
    }

    /// The launch picture over `regions` left.
    public func coverEnded(_ regions: Set<LaunchRegion>) {
        for region in regions { covered[region] = max(0, covered[region, default: 0] - 1) }
    }

    /// `view` has its data before its region (a terminal's frame from the last quit): it shows at
    /// once, with no fade, while the region's other views stay held.
    public func release(_ view: NSView) {
        guard held.values.contains(where: { $0.contains(view) }) else { return }
        for table in held.values { table.remove(view) }
        view.alphaValue = 1
    }

    /// Every region is ready (or will never get data: the daemon is unavailable): nothing stays
    /// held, and the window shows its final content (`onRevealed`).
    public func markAllReady() {
        deadlineTimer.cancel()
        for timer in ownDeadlines.values { timer.cancel() }
        for region in LaunchRegion.allCases { markReady(region) }
    }
}
