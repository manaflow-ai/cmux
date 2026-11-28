public import Foundation

/// Compact relative-activity bucket for a workspace row's trailing time label,
/// like a messaging list: "now" under a minute, then whole minutes, hours, and
/// days, and a month/day date past a week.
///
/// This is a pure value computation with an injected `now`, so the bucket (and
/// the numeric count inside it) is fully deterministic in tests. The UI layer
/// maps buckets to localized strings; keeping the arithmetic here means the
/// label can never silently depend on the wall clock the way
/// `Date.FormatStyle.relative` does (it ignores any injected reference date).
public enum MobileRelativeActivity: Equatable, Sendable {
    /// No real activity timestamp (epoch or distant-past placeholder).
    case none
    /// Less than a minute ago, including small clock skew into the future.
    case now
    /// Whole minutes ago, `1...59`.
    case minutes(Int)
    /// Whole hours ago, `1...23`.
    case hours(Int)
    /// Whole days ago, `1...6`.
    case days(Int)
    /// A week or more ago; render as a month/day date instead of "5 weeks ago".
    case monthDay

    /// Buckets `date` relative to `now`.
    ///
    /// - Parameters:
    ///   - date: The activity timestamp to bucket.
    ///   - now: The reference instant (injected for determinism).
    /// - Returns: The compact bucket for the trailing time label.
    public static func bucket(for date: Date, now: Date) -> MobileRelativeActivity {
        // Without a real activity timestamp the trailing slot stays empty
        // rather than echoing the epoch.
        guard date.timeIntervalSince1970 > 1 else { return .none }
        let interval = now.timeIntervalSince(date)
        // Mac/phone clock skew can put the latest activity slightly in the
        // future; anything under a minute in either direction reads "now"
        // rather than a negative or nonsense value.
        if interval < 60 { return .now }
        let minutes = Int(interval / 60)
        if minutes < 60 { return .minutes(minutes) }
        let hours = Int(interval / 3600)
        if hours < 24 { return .hours(hours) }
        let days = Int(interval / 86400)
        if days < 7 { return .days(days) }
        return .monthDay
    }
}
