/// Limits how often a page's title reaches its state.
///
/// A page that changes its title every frame (a timer, a counter) made every
/// state observer run each frame: the browser toolbar, the tab's rows and the
/// record writer (about 89 app wakeups/s on cmux14, msg 2654). The first change
/// after a quiet `interval` applies at once; changes inside the interval wait,
/// and only the latest applies when it ends. Pure: the tab owns the timer.
nonisolated struct TitleCoalescer: Equatable, Sendable {
    /// Seconds between two applied titles (at most 4 a second).
    static let interval: Double = 0.25

    /// A title to apply to the page state (nil clears it).
    struct Update: Equatable, Sendable {
        var title: String?
    }

    enum Decision: Equatable, Sendable {
        /// Apply this title now.
        case apply(Update)
        /// Keep it; call `fire(now:)` at this time.
        case wait(until: Double)
    }

    private var lastApplied: Double?
    private var pending: Update?

    /// A new title from the engine at `now` (seconds on any monotonic clock).
    mutating func offer(_ title: String?, now: Double) -> Decision {
        if let lastApplied, now - lastApplied < Self.interval {
            pending = Update(title: title)
            return .wait(until: lastApplied + Self.interval)
        }
        pending = nil
        lastApplied = now
        return .apply(Update(title: title))
    }

    /// The interval ended: the waiting title, if any.
    mutating func fire(now: Double) -> Update? {
        take(now: now)
    }

    /// Another page event comes: the waiting title goes first, so the state
    /// sees events in their order.
    mutating func flush(now: Double) -> Update? {
        take(now: now)
    }

    private mutating func take(now: Double) -> Update? {
        guard let update = pending else { return nil }
        pending = nil
        lastApplied = now
        return update
    }
}
