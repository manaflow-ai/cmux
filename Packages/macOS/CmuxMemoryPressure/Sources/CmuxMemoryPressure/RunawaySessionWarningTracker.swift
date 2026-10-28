/// Edge-triggered warning state per terminal: a session warns once when it
/// crosses the policy, stays warned through the hysteresis band, and can warn
/// again after it clears. A dismissed warning stays quiet until it clears.
public struct RunawaySessionWarningTracker<Key: Hashable & Sendable>: Sendable {
    /// Terminals currently over the policy.
    private(set) var warned: Set<Key> = []
    /// Warned terminals whose warning the user dismissed.
    private(set) var dismissed: Set<Key> = []

    /// Creates an empty tracker.
    public init() {}

    /// Ingests the current usage of every live terminal and returns the
    /// terminals that newly need a warning. Live terminals whose measurement
    /// is unavailable retain their warning and dismissal state; closed ones
    /// are forgotten.
    public mutating func ingest(
        _ usages: [Key: RunawaySessionUsage],
        unavailableKeys: Set<Key> = [],
        policy: RunawaySessionWarningPolicy
    ) -> Set<Key> {
        let live = Set(usages.keys).union(unavailableKeys)
        warned.formIntersection(live)
        dismissed.formIntersection(live)
        var newlyWarned: Set<Key> = []
        for (key, usage) in usages {
            if policy.isRunaway(usage) {
                if warned.insert(key).inserted { newlyWarned.insert(key) }
            } else if policy.hasCleared(usage) {
                warned.remove(key)
                dismissed.remove(key)
            }
        }
        return newlyWarned
    }

    /// Whether `key` has a warning the user should still see.
    public func isPresentable(_ key: Key) -> Bool {
        warned.contains(key) && !dismissed.contains(key)
    }

    /// Hides the warning for `key` until its session clears.
    public mutating func dismiss(_ key: Key) {
        guard warned.contains(key) else { return }
        dismissed.insert(key)
    }

    /// Forgets `key`, so a new runaway in the same terminal warns again.
    public mutating func reset(_ key: Key) {
        warned.remove(key)
        dismissed.remove(key)
    }
}
