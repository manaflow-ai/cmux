public import Foundation
public import SwiftUI

/// A `TimelineSchedule` that re-fires at a cadence proportional to how old a
/// timestamp is, so a relative-time label ("2 minutes ago") refreshes often
/// while the value changes quickly and rarely once it stops changing visibly.
///
/// Drive a `TimelineView` with `RelativeTimestampSchedule(modified:)` to keep a
/// relative-time `Text` current without a free-running per-second timer: a
/// timestamp under an hour old re-emits every minute, under a day every hour,
/// and older than a day once a day.
public struct RelativeTimestampSchedule: TimelineSchedule {
    /// The timestamp whose age determines the refresh cadence.
    public let modified: Date

    /// Creates a schedule that refreshes a relative-time label for `modified`.
    /// - Parameter modified: The timestamp being rendered relatively.
    public init(modified: Date) {
        self.modified = modified
    }

    public func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(current: startDate, modified: modified)
    }

    /// The next-refresh delay for a timestamp of the given age: 60s while under
    /// an hour old, an hour while under a day old, otherwise a day.
    static func refreshInterval(for modified: Date, now: Date = .now) -> TimeInterval {
        let age = max(0, now.timeIntervalSince(modified))
        if age < 3_600 { return 60 }
        if age < 86_400 { return 3_600 }
        return 86_400
    }

    /// Lazily produces the refresh instants, each spaced from the prior one by
    /// `refreshInterval(for:now:)` evaluated at that instant so the cadence
    /// widens as the timestamp ages.
    public struct Entries: Sequence, IteratorProtocol {
        var current: Date
        let modified: Date

        public mutating func next() -> Date? {
            let date = current
            current = current.addingTimeInterval(RelativeTimestampSchedule.refreshInterval(for: modified, now: date))
            return date
        }
    }
}
