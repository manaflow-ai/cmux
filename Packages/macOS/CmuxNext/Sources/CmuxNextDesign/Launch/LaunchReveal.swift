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
/// ready, windows opened later show it at once.
@MainActor
@Observable
public final class LaunchReveal {
    public static let shared = LaunchReveal()

    /// Regions whose data has arrived. Only grows.
    public private(set) var ready: Set<LaunchRegion> = []
    @ObservationIgnored private var held: [LaunchRegion: NSHashTable<NSView>] = [:]
    @ObservationIgnored private var waiters: [LaunchRegion: [@MainActor () -> Void]] = [:]
    @ObservationIgnored private let deadlineTimer: DemandTimer
    /// The deadlines of regions made after the window (`LaunchRegion.hasOwnDeadline`).
    @ObservationIgnored private var ownDeadlines: [LaunchRegion: DemandTimer] = [:]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let deadline: Duration

    /// - Parameter deadline: How long after the first `hold` every region
    ///   shows anyway.
    public init(clock: any Clock<Duration> = ContinuousClock(), deadline: Duration = .milliseconds(1500)) {
        deadlineTimer = DemandTimer(owner: "launch.reveal-deadline", clock: clock)
        self.clock = clock
        self.deadline = deadline
    }

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
        guard region.hasOwnDeadline else {
            deadlineTimer.scheduleIfIdle(after: deadline) { @MainActor [weak self] in
                for region in LaunchRegion.allCases where !region.hasOwnDeadline { self?.markReady(region) }
            }
            return
        }
        let timer = ownDeadlines[region] ?? DemandTimer(owner: "launch.reveal-deadline.\(region.rawValue)", clock: clock)
        ownDeadlines[region] = timer
        if alone {
            timer.schedule(after: deadline) { @MainActor [weak self] in self?.markReady(region) }
        } else {
            timer.scheduleIfIdle(after: deadline) { @MainActor [weak self] in self?.markReady(region) }
        }
    }

    /// Runs `work` once `region` is ready (at once when it is).
    public func whenReady(_ region: LaunchRegion, _ work: @escaping @MainActor () -> Void) {
        if isReady(region) { work() } else { waiters[region, default: []].append(work) }
    }

    /// `region`'s data arrived: its held views fade in. Later calls do nothing.
    public func markReady(_ region: LaunchRegion) {
        guard ready.insert(region).inserted else { return }
        let views = held.removeValue(forKey: region)?.allObjects ?? []
        for view in views {
            // The model value at once; the fade runs on the layer.
            view.alphaValue = 1
            // A view whose window has not drawn it yet (no presentation layer: a relaunch's saved
            // tabs before the first frame) shows in its first frame, not faded in from clear.
            if let layer = view.layer, layer.presentation() != nil { Motion.panes.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0)) }
        }
        for work in waiters.removeValue(forKey: region) ?? [] { work() }
    }

    /// `view` has its data before its region (a terminal's frame from the last quit): it shows at
    /// once, with no fade, while the region's other views stay held.
    public func release(_ view: NSView) {
        guard held.values.contains(where: { $0.contains(view) }) else { return }
        for table in held.values { table.remove(view) }
        view.alphaValue = 1
    }

    /// Every region is ready (or will never be): nothing stays held.
    public func markAllReady() {
        deadlineTimer.cancel()
        for timer in ownDeadlines.values { timer.cancel() }
        for region in LaunchRegion.allCases { markReady(region) }
    }
}
