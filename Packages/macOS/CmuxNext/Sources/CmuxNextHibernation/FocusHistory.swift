/// When the person showed each tab lately, for the hibernation ranking (`HibernationPlanner.Candidate`
/// `recentFocusCount`): at most `limit` shows per tab, within `window` seconds. Pure.
package nonisolated struct FocusHistory: Sendable {
    /// Seconds of focus history a tab's ranking counts.
    package static let window: Double = 3_600
    package static let limit = 64
    private var shows: [String: [ContinuousClock.Instant]] = [:]

    package init() {}

    /// Records a show of tab `key`, dropping shows older than `window`.
    package mutating func note(_ key: String, at now: ContinuousClock.Instant) {
        var times = shows[key, default: []].filter { Self.seconds(now - $0) < Self.window }
        times.append(now)
        if times.count > Self.limit { times.removeFirst(times.count - Self.limit) }
        shows[key] = times
    }

    /// Shows of tab `key` within `window` of `now`.
    package func count(_ key: String, now: ContinuousClock.Instant) -> Int {
        shows[key]?.filter { Self.seconds(now - $0) < Self.window }.count ?? 0
    }

    package mutating func forget(_ key: String) { shows[key] = nil }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
