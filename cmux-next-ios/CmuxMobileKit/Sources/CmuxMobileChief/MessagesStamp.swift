import Foundation

/// The conversation list's date column, as Messages writes it: the time for
/// today, "Yesterday", the weekday within the last week, else the date.
public struct MessagesStamp: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale

    public init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    public func string(for date: Date) -> String {
        var calendar = calendar
        calendar.locale = locale
        if calendar.isDate(date, inSameDayAs: now) {
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.calendar = calendar
            style.locale = locale
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDay, to: startOfToday).day ?? 0
        if days == 1 { return String(localized: "Yesterday") }
        if days > 1, days < 7 {
            var style = Date.FormatStyle().weekday(.wide)
            style.calendar = calendar
            style.locale = locale
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        var style = Date.FormatStyle(date: .numeric, time: .omitted)
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
