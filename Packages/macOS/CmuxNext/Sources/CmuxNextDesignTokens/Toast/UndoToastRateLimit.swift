package import Foundation

/// How often a destructive action's undo toast (a close) may show: at most
/// one new toast per id in ``minimumGap``. A close made while the toast still
/// shows joins it (its owner's job) and is not counted here. A close the limit
/// keeps quiet loses only the toast: Reopen Closed (Cmd-Shift-T) and History
/// still bring it back (Lawrence 2026-10-18: toasts show "way too often").
///
/// ```swift
/// var limit = UndoToastRateLimit(minimumGap: .seconds(30))
/// limit.allows("tab-closed", at: .now) // true, then false for 30 s
/// ```
public nonisolated struct UndoToastRateLimit: Sendable {
    /// The shortest time between two new toasts with the same id.
    public var minimumGap: Duration
    private var lastShown: [String: ContinuousClock.Instant] = [:]

    /// - Parameter minimumGap: the shortest time between two new toasts with one id; zero turns the limit off.
    public init(minimumGap: Duration = .seconds(30)) {
        self.minimumGap = minimumGap
    }

    /// Whether a new toast `id` may show at `now`; a true answer counts it as shown.
    public mutating func allows(_ id: String, at now: ContinuousClock.Instant) -> Bool {
        if let last = lastShown[id], now - last < minimumGap { return false }
        lastShown[id] = now
        return true
    }
}
