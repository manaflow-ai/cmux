public import AppKit
import CmuxNextWakeups
import Observation

/// Launch load-in, region by region: a view held for a region stays clear
/// on the window glass until that region's data is ready, then fades in
/// (`MotionFade.fadeIn`; capped under Reduce Motion), independently of the
/// other regions, never all at once. A view held after its region is
/// ready shows at once, so a fast launch adds no fade and no delay.
///
/// Producers call `markReady` where the data lands (the sidebar's first
/// rows, the first non-empty tab strip, the first terminal frame); a
/// launch that cannot produce a region (daemon unavailable) calls
/// `markAllReady`. A region whose data never arrives (no tabs, a pane
/// that never draws) is released by the deadline, which the first `hold`
/// arms: a missed producer costs a short delay, never a blank window.
///
/// Call `markReady` where real data lands, not on an empty placeholder
/// model, and hold containers, not views that animate their own alpha.
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
    @ObservationIgnored private let deadline: Duration

    /// - Parameter deadline: How long after the first `hold` every region
    ///   shows anyway.
    public init(clock: any Clock<Duration> = ContinuousClock(), deadline: Duration = .milliseconds(1500)) {
        deadlineTimer = DemandTimer(owner: "launch.reveal-deadline", clock: clock)
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
        table.add(view)
        deadlineTimer.scheduleIfIdle(after: deadline) { @MainActor [weak self] in
            self?.markAllReady()
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
        if !views.isEmpty {
            Motion.animate(.fadeIn) {
                for view in views { view.animator().alphaValue = 1 }
            }
        }
        for work in waiters.removeValue(forKey: region) ?? [] { work() }
    }

    /// Every region is ready (or will never be): nothing stays held.
    public func markAllReady() {
        deadlineTimer.cancel()
        for region in LaunchRegion.allCases { markReady(region) }
    }
}
