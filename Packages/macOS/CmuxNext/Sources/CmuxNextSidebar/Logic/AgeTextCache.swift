import Foundation
import os

/// Remembers the age labels rows draw (`3d`, `2w`, a time today), so a layout of 10,000 rows formats each distinct
/// label once instead of once per row (a `DateComponentsFormatter` per row was most of a 10k group's open, unfold
/// and reorder time). Keys carry the locale and calendar, so a language change makes new labels.
///
/// One cache lives in each ``SidebarLayoutOptions``, so it spans one layout pass and holds no state between them. All
/// caches compare equal: what a cache holds never changes what a layout draws.
nonisolated final class AgeTextCache: Hashable, Sendable {
    // OSAllocatedUnfairLock: layout runs off the main actor too; a short dictionary read or write, never held across work.
    private let labels = OSAllocatedUnfairLock(initialState: [Key: String]())
    private static let limit = 4_096

    static func == (_: AgeTextCache, _: AgeTextCache) -> Bool { true }
    func hash(into _: inout Hasher) {}

    private struct Key: Hashable {
        /// Whole days, or minutes since 1970 for a time today.
        var value: Int
        var today: Bool
        var locale: String
        var timeZone: String
    }

    /// The label for `key`, made by `make` the first time.
    func label(days: Int?, minute: Int, locale: Locale, timeZone: TimeZone, make: () -> String) -> String {
        let key = Key(value: days ?? minute, today: days == nil, locale: locale.identifier, timeZone: timeZone.identifier)
        if let hit = labels.withLock({ $0[key] }) { return hit }
        let made = make()
        labels.withLock {
            if $0.count >= Self.limit { $0.removeAll(keepingCapacity: true) }
            $0[key] = made
        }
        return made
    }
}
