public import Foundation

/// Once-per-period dedup for the iOS daily + hourly active retention pings.
///
/// Mirrors the macOS `PostHogAnalytics` `cmux_daily_active` / `cmux_hourly_active`
/// pattern: the app records a UTC day/hour key the first time it is active in a
/// period, and suppresses the event for the rest of that period. Together with
/// the shared Stack-user-id distinct id (the iOS proxy stamps `user.id`), this
/// makes iOS DAU + hourly retention line up symmetrically with macOS.
///
/// The type holds no mutable in-memory state: persistence lives in the injected
/// `UserDefaults` (so the dedup survives relaunches and is testable without
/// `.standard`), and the period boundaries are computed from injected `Date`s.
/// `claimDaily`/`claimHourly` are the only mutating calls — each returns whether
/// the caller should emit and atomically records the period when it does, so a
/// double foreground in the same period emits once.
public struct AnalyticsActivePeriodStore: Sendable {
    private static let lastDayKey = "dev.cmux.analytics.lastActiveDayUTC"
    private static let lastHourKey = "dev.cmux.analytics.lastActiveHourUTC"

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates an active-period store.
    /// - Parameter defaults: The persistence store. Inject a suite-scoped store
    ///   in tests; the app uses `.standard`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The UTC day string (`yyyy-MM-dd`) for `date`. Exposed so the emitted
    /// event can carry the same `day_utc` property macOS uses.
    public static func dayUTCString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// The UTC hour string (`yyyy-MM-dd'T'HH`) for `date`. Exposed so the emitted
    /// event can carry the same `hour_utc` property macOS uses.
    public static func hourUTCString(_ date: Date) -> String {
        hourFormatter.string(from: date)
    }

    /// Claims the daily-active period for `date`.
    ///
    /// - Returns: The UTC day key when this is the first active moment of that
    ///   UTC day (and records it so the rest of the day is suppressed), or `nil`
    ///   when the day was already claimed.
    @discardableResult
    public func claimDaily(now date: Date) -> String? {
        let day = Self.dayUTCString(date)
        if defaults.string(forKey: Self.lastDayKey) == day { return nil }
        defaults.set(day, forKey: Self.lastDayKey)
        return day
    }

    /// Claims the hourly-active period for `date`.
    ///
    /// - Returns: The UTC hour key when this is the first active moment of that
    ///   UTC hour (and records it so the rest of the hour is suppressed), or
    ///   `nil` when the hour was already claimed.
    @discardableResult
    public func claimHourly(now date: Date) -> String? {
        let hour = Self.hourUTCString(date)
        if defaults.string(forKey: Self.lastHourKey) == hour { return nil }
        defaults.set(hour, forKey: Self.lastHourKey)
        return hour
    }

    // Type-scoped (not file-scope free funcs) to satisfy the iOS package
    // conventions lint (`lint-ios-package-conventions.sh` errors on free
    // functions). The formatters are stateless after init and only read.
    private static let dayFormatter = makeUTCFormatter("yyyy-MM-dd")
    private static let hourFormatter = makeUTCFormatter("yyyy-MM-dd'T'HH")

    private static func makeUTCFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}
