/// When the person showed each tab lately, which ranks hidden pages for hibernation (`ContentDiscardPlanner.idleness`):
/// at most ``limit`` shows per tab, within ``window`` seconds.
package struct TabFocusHistory {
    /// Seconds of focus history a tab's ranking counts.
    package static let window: Duration = .seconds(3_600)
    package static let limit = 64

    private var shownAt: [String: [ContinuousClock.Instant]] = [:]

    package init() {}

    /// Records a show of tab `key`, dropping shows older than ``window``.
    package mutating func note(_ key: String, at now: ContinuousClock.Instant) {
        var times = shownAt[key, default: []].filter { now - $0 < Self.window }
        times.append(now)
        if times.count > Self.limit { times.removeFirst(times.count - Self.limit) }
        shownAt[key] = times
    }

    /// Shows of tab `key` within ``window`` of `now`.
    package func count(_ key: String, now: ContinuousClock.Instant) -> Int {
        shownAt[key]?.filter { now - $0 < Self.window }.count ?? 0
    }

    package mutating func forget(_ key: String) {
        shownAt[key] = nil
    }
}
