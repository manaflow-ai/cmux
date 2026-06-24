public import Foundation
public import SwiftUI

/// A `TimelineSchedule` that re-renders a relative timestamp at a cadence that
/// coarsens as the timestamp ages.
///
/// Recent timestamps update every minute; within a day, hourly; older than a day,
/// daily. The cadence comes from ``Foundation/Date/relativeTimestampRefreshInterval(now:)``
/// so the schedule and any other relative-time consumer share one definition.
public struct RelativeTimestampSchedule: TimelineSchedule {
    private let modified: Date

    /// Creates a schedule whose cadence is keyed off how old `modified` is.
    /// - Parameter modified: The timestamp being displayed relative to "now".
    public init(modified: Date) {
        self.modified = modified
    }

    public func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(current: startDate, modified: modified)
    }

    /// The lazy sequence of refresh instants this schedule emits.
    public struct Entries: Sequence, IteratorProtocol {
        var current: Date
        let modified: Date

        public mutating func next() -> Date? {
            let date = current
            current = current.addingTimeInterval(modified.relativeTimestampRefreshInterval(now: date))
            return date
        }
    }
}

extension Date {
    /// How long until a relative timestamp for this date should next refresh,
    /// measured from `now`.
    ///
    /// Coarsens with age so an old timestamp does not redraw every minute: under
    /// an hour old refreshes every 60s, under a day every hour, otherwise daily.
    /// - Parameter now: The reference instant; defaults to the current instant.
    /// - Returns: The interval, in seconds, until the next refresh.
    public func relativeTimestampRefreshInterval(now: Date = .now) -> TimeInterval {
        let age = max(0, now.timeIntervalSince(self))
        if age < 3_600 { return 60 }
        if age < 86_400 { return 3_600 }
        return 86_400
    }
}
