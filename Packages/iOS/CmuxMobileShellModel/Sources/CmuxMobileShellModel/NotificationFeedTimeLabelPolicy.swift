public import Foundation
internal import CmuxMobileSupport

/// Formats notification timestamps using compact relative labels for today and local times otherwise.
public struct NotificationFeedTimeLabelPolicy: Sendable {
    private let now: Date
    private let calendar: Calendar
    private let locale: Locale

    /// Creates a time-label policy.
    /// - Parameters:
    ///   - now: The instant used for relative-time calculations.
    ///   - calendar: The calendar and time zone used to identify today.
    ///   - locale: The locale used for older short-time labels.
    public init(now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    /// Formats a notification creation instant.
    /// - Parameter date: The notification creation instant.
    /// - Returns: `now`, a compact minute/hour count for today, or a localized short time.
    public func label(for date: Date) -> String {
        guard calendar.isDate(date, inSameDayAs: now) else {
            var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 {
            return L10n.string("mobile.notifications.time.now", defaultValue: "now")
        }
        if elapsed < 3_600 {
            let format = L10n.string("mobile.notifications.time.minutes", defaultValue: "%dm")
            return String(format: format, Int(elapsed / 60))
        }
        let format = L10n.string("mobile.notifications.time.hours", defaultValue: "%dh")
        return String(format: format, Int(elapsed / 3_600))
    }
}
