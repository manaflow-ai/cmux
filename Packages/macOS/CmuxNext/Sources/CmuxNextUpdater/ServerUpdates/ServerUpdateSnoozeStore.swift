public import Foundation

/// Which server notices the person snoozed and until when, in injected `UserDefaults`.
public final class ServerUpdateSnoozeStore {
    /// The defaults key holding `[notice id: snoozed-until seconds since 1970]`.
    public static let key = "cmux.serverUpdates.snoozedUntil"
    private let defaults: UserDefaults

    /// - Parameter defaults: Where snoozes persist (tests pass a suite of their own).
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether notice `id` is snoozed at `now`.
    public func isSnoozed(_ id: String, at now: Date) -> Bool {
        guard let until = entries[id] else { return false }
        return now.timeIntervalSince1970 < until
    }

    /// Snoozes notice `id` until `until`, dropping snoozes that already ended.
    public func snooze(_ id: String, until: Date, now: Date) {
        var next = entries.filter { $0.value > now.timeIntervalSince1970 }
        next[id] = until.timeIntervalSince1970
        defaults.set(next, forKey: Self.key)
    }

    private var entries: [String: Double] {
        (defaults.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
    }
}
