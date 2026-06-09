public import Foundation

/// Coordinates autosave-only state while callers collect snapshots and perform persistence writes.
@MainActor
public final class SessionAutosaveCoordinator<CachedSnapshot: Sendable> {
    /// Identity token for a single autosave run.
    public final class RunToken: @unchecked Sendable {
        /// Creates a run token used to ignore stale autosave completions.
        public init() {}
    }

    private var autosaveTask: Task<Void, Never>?
    private var activeRunToken: RunToken?
    private var isTickInFlight = false
    private var lastAutosaveFingerprint: Int?
    private var lastAutosavePersistedAt: Date = .distantPast
    private var cachedSnapshot: CachedSnapshot?
    private var lastTypingActivityAt: TimeInterval = 0

    /// Creates an empty coordinator.
    public init() {}

    /// Cancels the current autosave task and clears in-flight state.
    public func cancelInFlightTick() {
        autosaveTask?.cancel()
        autosaveTask = nil
        activeRunToken = nil
        isTickInFlight = false
    }

    /// Starts a tick if no tick is already running.
    @discardableResult
    public func beginTick(startTask: (RunToken) -> Task<Void, Never>) -> Bool {
        guard !isTickInFlight else { return false }
        let runToken = RunToken()
        isTickInFlight = true
        activeRunToken = runToken
        autosaveTask = startTask(runToken)
        return true
    }

    /// Finishes the active tick when the provided token matches the running tick.
    public func finishTick(runToken: RunToken) {
        guard activeRunToken === runToken else { return }
        autosaveTask = nil
        activeRunToken = nil
        isTickInFlight = false
    }

    /// Records recent typing so autosave can avoid competing with keypress handling.
    public func recordTypingActivity(nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastTypingActivityAt = nowUptime
    }

    /// Returns the remaining quiet period when typing happened too recently.
    public func remainingTypingQuietPeriod(
        quietPeriod: TimeInterval,
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < quietPeriod else { return nil }
        return quietPeriod - elapsed
    }

    /// Stores snapshot metadata that can be reused by cheap autosave paths.
    public func cacheSnapshot(_ snapshot: CachedSnapshot) {
        cachedSnapshot = snapshot
    }

    /// Returns explicit snapshot metadata, cached metadata, or a freshly loaded fallback.
    public func snapshotForCheapSave(
        explicitSnapshot: CachedSnapshot?,
        fallbackLoader: () -> CachedSnapshot
    ) -> CachedSnapshot {
        if let explicitSnapshot {
            cachedSnapshot = explicitSnapshot
            return explicitSnapshot
        }
        if let cachedSnapshot {
            return cachedSnapshot
        }

        let snapshot = fallbackLoader()
        cachedSnapshot = snapshot
        return snapshot
    }

    /// Loads snapshot metadata off the main actor.
    public func loadSnapshot(_ loader: @escaping @Sendable () -> CachedSnapshot) async -> CachedSnapshot {
        await Task.detached(priority: .utility) {
            loader()
        }.value
    }

    /// Returns true when an unchanged autosave may be skipped within the staleness window.
    public func shouldSkipSaveForUnchangedFingerprint(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        currentFingerprint: Int?,
        now: Date,
        maximumAutosaveSkippableInterval: TimeInterval = 5 * 60
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let lastAutosaveFingerprint,
              let currentFingerprint,
              lastAutosaveFingerprint == currentFingerprint else {
            return false
        }

        return now.timeIntervalSince(lastAutosavePersistedAt) < maximumAutosaveSkippableInterval
    }

    /// Records a successful cheap autosave fingerprint.
    public func recordSuccessfulSave(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Int?
    ) {
        guard !isTerminatingApp, !includeScrollback else { return }
        lastAutosaveFingerprint = fingerprint
        lastAutosavePersistedAt = persistedAt
    }
}
