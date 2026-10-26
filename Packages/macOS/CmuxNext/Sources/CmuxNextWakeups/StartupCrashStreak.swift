/// Whether this launch may read what the last runs saved for a fast start:
/// window pictures, the daemon launch snapshot, the sidebar and Home
/// caches, terminal frames, agent images, Debug overrides and the Chromium
/// restore order. A reader that is told `.skip` takes the live path.
public enum LaunchCaches: Equatable, Sendable {
    case use
    case skip(LaunchCacheSkipReason)

    public var skipped: Bool { self != .use }

    public var skipReason: LaunchCacheSkipReason? {
        if case .skip(let reason) = self { return reason }
        return nil
    }

    /// Runs `read` (a launch cache's load and decode) unless the caches are
    /// skipped; then the caller takes its live path.
    public func read<Value>(_ read: () throws -> Value?) rethrows -> Value? {
        skipped ? nil : try read()
    }
}

/// Why this launch does not read its launch caches.
public enum LaunchCacheSkipReason: String, Sendable {
    /// Runs in a row ended before `startup_complete` (``StartupCrashStreak``).
    case crashStreak
}

/// Runs in a row that ended before `startup_complete`, as Chrome counts
/// runs that did not write their clean-exit beacon
/// (components/metrics/clean_exit_beacon.cc) and falls back to a safe seed
/// at a threshold (components/variations/service/safe_seed_manager.cc).
/// Here the beacon is `startup_complete`: a cache that crashes or hangs
/// every launch before it is skipped from the third launch on.
public struct StartupCrashStreak: Equatable, Sendable {
    /// At this many unfinished runs in a row the launch skips its caches.
    public static let threshold = 2

    /// Runs in a row, just before this one, that ended before
    /// `startup_complete`.
    public let unfinishedRuns: Int

    public init(unfinishedRuns: Int = 0) {
        // The count comes from a file: a corrupt value neither traps nor
        // goes negative.
        self.unfinishedRuns = min(max(unfinishedRuns, 0), 1_000)
    }

    /// The streak of the next launch, after a run with this streak ended.
    /// `finished`: it reached `startup_complete`, or it ended because
    /// someone asked it to.
    public func next(finished: Bool) -> StartupCrashStreak {
        StartupCrashStreak(unfinishedRuns: finished ? 0 : unfinishedRuns + 1)
    }

    public var launchCaches: LaunchCaches {
        unfinishedRuns >= Self.threshold ? .skip(.crashStreak) : .use
    }
}
