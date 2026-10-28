import CmuxNextCompat
public import Foundation

/// Whether this launch reads what the last quit saved for a fast first frame: the window and browser pictures, the
/// terminal frames, the agent pages, the sidebar snapshot, the daemon's launch snapshot and the Home list. A cache
/// that crashes or hangs its reader (a trapping decoder) would end every launch the same way, so after
/// ``crashStreakThreshold`` runs in a row ended before their startup completed, the launch skips them all and opens
/// live; the first run whose startup completes resets the streak. The decision is pure (its only file calls are the
/// ``Beacon``'s): the app's run marker (`AppRunMarker`) supplies the previous run and records this one's startup.
///
/// The launch caches are read on the files lane from `main`, beside the run marker's own launch read and before the
/// marker writes this run's `run.json`: each read asks the launch's one ``Gate``, and the first ask
/// writes this launch's ``Beacon`` before any cache is read, so a launch a cache ends before its marker is counted.
///
/// Chrome's `VariationsSafeModeTracker` model: the clean-exit beacon (components/metrics/clean_exit_beacon.cc) marks
/// a session that did not end cleanly, `variations_crash_streak` counts them in a row, and past a threshold the next
/// start skips the latest seed for a safe one (components/variations/service/safe_seed_manager.cc). Here the beacon
/// is the startup completion: a launch cache can only break a launch before it.
///
/// ```swift
/// let safeMode = LaunchSafeMode.after(startupComplete: false, incompleteLaunches: 1, endedAsAsked: false,
///                                     machineRestarted: false)   // the second run in a row: reason crashStreak
/// let pictures = BrowserLaunchPictures(state: state, work: work, reader: LaunchFileReader().gated { safeMode.readsLaunchCaches })
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

    /// The first record of a launch, written by its ``Gate`` before any launch cache is read: which process it is
    /// and the streak it launched with (`run.launch` beside the run marker). A launch that ended before its marker
    /// wrote `run.json` left only this, so the next launch counts it from here.
    public nonisolated struct Beacon: Codable, Equatable, Sendable {
        public var pid: Int32
        /// The process's kernel start in Unix microseconds; nil when the kernel does not give it.
        public var processStart: UInt64?
        /// When the launch began: a marker newer than this record is a later run's.
        public var launched: Date
        /// The boot the launch was in (`kern.bootsessionuuid` as hex); nil when unknown.
        public var bootSession: String?
        /// The streak the launch began with (``LaunchSafeMode/incompleteLaunches``).
        public var incompleteLaunches: Int

        public init(pid: Int32, processStart: UInt64?, launched: Date, bootSession: String?, incompleteLaunches: Int) {
            (self.pid, self.processStart, self.launched) = (pid, processStart, launched)
            (self.bootSession, self.incompleteLaunches) = (bootSession, incompleteLaunches)
        }

        /// This record is process `pid`'s (started at `processStart`).
        public func isProcess(pid: Int32, processStart: UInt64?) -> Bool {
            self.pid == pid && self.processStart == processStart
        }

        /// The streak after this launch when it ended before its marker was written (so before its startup
        /// completed, with no quit asked for), seen from boot `current`: one more, unless the machine's restart
        /// ended it.
        public func ended(bootSession current: String?) -> LaunchSafeMode {
            let restarted = bootSession != nil && current != nil && bootSession != current
            return LaunchSafeMode(incompleteLaunches: incompleteLaunches + (restarted ? 0 : 1))
        }

        /// The record in `url`; nil when there is none or it does not decode. Blocking: on a launch lane.
        public static func read(_ url: URL) -> Beacon? {
            guard let data = try? Data(blockingContentsOf: url) else { return nil }
            return try? JSONDecoder().blockingDecode(Beacon.self, from: data)
        }

        /// Writes the record to `url` atomically. Blocking: on a launch lane.
        public func store(at url: URL) throws {
            try JSONEncoder().encode(self).blockingWrite(to: url, options: .atomic)
        }
    }

    /// The launch's one decision, asked by every launch cache's read on its lane and by the run marker's launch
    /// read: the first ask decides (`decide`, blocking: it reads the previous run's records and writes this
    /// launch's ``Beacon`` before it returns), later asks get the same answer.
    ///
    /// ```swift
    /// let gate = LaunchSafeMode.Gate(decide: { AppRunMarker.launchSafeMode(directory: folder) }, mark: mark)
    /// let reader = LaunchFileReader().gated { gate.safeMode.readsLaunchCaches }   // every cache's reads
    /// ```
    public nonisolated final class Gate: Sendable {
        private let decide: @Sendable () -> LaunchSafeMode
        private let mark: @Sendable (String) -> Void
        /// The decision once made. Lock carve-out: the launch's lane threads take it for one load or store each;
        /// `decide`'s file work runs outside it.
        private let decided = Mutex<LaunchSafeMode?>(nil)

        /// - Parameters:
        ///   - decide: Makes the decision; it may run more than once when two reads ask at once, so it must give
        ///     the same answer each time (it recognizes the beacon it already wrote).
        ///   - mark: Records ``Reason/mark`` once when the launch skips the caches.
        public init(decide: @escaping @Sendable () -> LaunchSafeMode, mark: @escaping @Sendable (String) -> Void = { _ in }) {
            (self.decide, self.mark) = (decide, mark)
        }

        /// A gate that always answers `safeMode` (tests, launches with no run marker).
        public convenience init(fixed safeMode: LaunchSafeMode) {
            self.init(decide: { safeMode })
        }

        /// The decision, made now on the first ask. Blocking on that ask: ask it on a launch lane.
        public var safeMode: LaunchSafeMode {
            if let made = decision { return made }
            let made = decide()
            let (answer, first) = decided.withLock { stored -> (LaunchSafeMode, Bool) in
                if let stored { return (stored, false) }
                stored = made
                return (made, true)
            }
            if first, let reason = answer.reason { mark(reason.mark) }
            return answer
        }

        /// The decision when one was made; nil before the first ask. Never blocks.
        public var decision: LaunchSafeMode? {
            decided.withLock { $0 }
        }
    }
}
