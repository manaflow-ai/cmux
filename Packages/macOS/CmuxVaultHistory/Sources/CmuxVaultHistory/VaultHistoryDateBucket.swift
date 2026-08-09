public import Foundation

/// Browser-history-style date buckets ordered from newest to oldest.
public enum VaultHistoryDateBucket: Int, CaseIterable, Identifiable, Sendable {
    /// Events in the rolling 24-hour window or on the current calendar day.
    case last24Hours
    /// Events on the previous calendar day that are outside the rolling window.
    case yesterday
    /// Older events in the current calendar week.
    case thisWeek
    /// Older events in the current calendar month.
    case thisMonth
    /// Events preceding the current calendar month.
    case older

    /// Stable ordinal identity used by grouped views.
    public var id: Int { rawValue }

    /// Classifies a timestamp relative to an injected clock and calendar.
    ///
    /// - Parameters:
    ///   - date: Event timestamp to classify.
    ///   - now: Reference time used for the rolling 24-hour window.
    ///   - calendar: Calendar used for day, week, and month boundaries.
    /// - Returns: The single date bucket containing `date`.
    public static func bucket(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> VaultHistoryDateBucket {
        if date >= now.addingTimeInterval(-24 * 60 * 60)
            || calendar.isDate(date, inSameDayAs: now) {
            return .last24Hours
        }
        if isYesterday(date, now: now, calendar: calendar) {
            return .yesterday
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            return .thisMonth
        }
        return .older
    }

    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
            return false
        }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}
