/// Whether this launch reads what the last quit saved for a fast first frame: the window and browser pictures, the
/// terminal frames, the agent pages, the sidebar snapshot, the daemon's launch snapshot and the Home list. A cache
/// that crashes or hangs its reader (a trapping decoder) would end every launch the same way, so after
/// ``crashStreakThreshold`` runs in a row ended before their startup completed, the launch skips them all and opens
/// live; the first run whose startup completes resets the streak. Pure: the app's run marker (`AppRunMarker`)
/// supplies the previous run and records this one's startup.
///
/// Chrome's `VariationsSafeModeTracker` model: the clean-exit beacon (components/metrics/clean_exit_beacon.cc) marks
/// a session that did not end cleanly, `variations_crash_streak` counts them in a row, and past a threshold the next
/// start skips the latest seed for a safe one (components/variations/service/safe_seed_manager.cc). Here the beacon
/// is the startup completion: a launch cache can only break a launch before it.
///
/// ```swift
/// let safeMode = LaunchSafeMode.after(startupComplete: false, incompleteLaunches: 1, endedAsAsked: false,
///                                     machineRestarted: false)   // the second run in a row: reason crashStreak
/// safeMode.readLaunchCaches(mark: { DebugTimings.markLaunch($0) }) { pictures.prefetch() }
/// ```
public nonisolated struct LaunchSafeMode: Equatable, Sendable {
    /// Runs in a row ended before their startup completed that make the next launch skip the caches.
    public static let crashStreakThreshold = 2

    /// Why a launch skips its caches.
    public nonisolated enum Reason: String, Sendable {
        case crashStreak

        /// The launch mark that records it.
        public var mark: String { "launch_caches_skipped.\(rawValue)" }
    }

    /// The runs in a row before this launch that ended before their startup completed, with no quit asked for.
    public let incompleteLaunches: Int

    /// A launch after a run whose startup completed, that quit as asked, or a first launch.
    public static let noStreak = LaunchSafeMode(incompleteLaunches: 0)

    public init(incompleteLaunches: Int) {
        self.incompleteLaunches = max(0, incompleteLaunches)
    }

    /// Why this launch skips the launch caches; nil when it reads them.
    public var reason: Reason? { incompleteLaunches >= Self.crashStreakThreshold ? .crashStreak : nil }
    public var readsLaunchCaches: Bool { reason == nil }

    /// The streak after the previous run, from what its marker recorded. A run whose startup completed, or that
    /// quit as asked, resets it; a marker from before these fields (`startupComplete` nil) never counts; a run the
    /// machine's restart ended neither adds to it nor resets it.
    ///
    /// - Parameters:
    ///   - startupComplete: The run's startup completed.
    ///   - incompleteLaunches: The streak the run launched with.
    ///   - endedAsAsked: Someone asked the run to quit (a quit that had begun, or a requested-quit signal).
    ///   - machineRestarted: The machine's restart or power loss ended the run, not a crash or a kill.
    public static func after(startupComplete: Bool?, incompleteLaunches: Int?, endedAsAsked: Bool,
                             machineRestarted: Bool) -> LaunchSafeMode {
        guard !endedAsAsked, startupComplete == false else { return .noStreak }
        return LaunchSafeMode(incompleteLaunches: (incompleteLaunches ?? 0) + (machineRestarted ? 0 : 1))
    }

    /// Runs `reads`, the launch caches' reads, unless this launch skips them; a skip records ``Reason/mark`` by `mark`.
    public func readLaunchCaches(mark: (String) -> Void, _ reads: () -> Void) {
        guard let reason else { return reads() }
        mark(reason.mark)
    }
}
