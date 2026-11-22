import Foundation

/// The conversation list's date column, as Messages writes it: the time for
/// today, "Yesterday", the weekday within the last week, else the date.
/// Its day boundaries and formats are worked out once (one stamp serves every
/// row of a pass), not again for each row.
public struct MessagesStamp: Sendable {
    public var now: Date { didSet { prepare() } }
    public var calendar: Calendar { didSet { prepare() } }
    public var locale: Locale { didSet { prepare() } }

    private var startOfToday = Date.distantPast
    private var startOfTomorrow = Date.distantPast
    private var startOfYesterday = Date.distantPast
    /// Six days ago: the oldest day named by its weekday.
    private var startOfWeek = Date.distantPast
    private var time = Date.FormatStyle()
    private var weekday = Date.FormatStyle()
    private var numeric = Date.FormatStyle()

    public init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        prepare()
    }

    private mutating func prepare() {
        var calendar = calendar
        calendar.locale = locale
        startOfToday = calendar.startOfDay(for: now)
        startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? .distantFuture
        startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfYesterday
        func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
            var style = base
            style.calendar = calendar
            style.locale = locale
            style.timeZone = calendar.timeZone
            return style
        }
        time = style(Date.FormatStyle(date: .omitted, time: .shortened))
        weekday = style(Date.FormatStyle().weekday(.wide))
        numeric = style(Date.FormatStyle(date: .numeric, time: .omitted))
    }

    public func string(for date: Date) -> String {
        if date >= startOfToday, date < startOfTomorrow { return date.formatted(time) }
        if date >= startOfYesterday, date < startOfToday { return String(localized: "Yesterday") }
        if date >= startOfWeek, date < startOfYesterday { return date.formatted(weekday) }
        return date.formatted(numeric)
    }
}
