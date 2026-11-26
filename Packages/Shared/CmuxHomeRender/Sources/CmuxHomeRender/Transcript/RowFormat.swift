import Foundation

/// Dates in separators, in the viewer's locale and time zone.
@MainActor
final class RowFormat {
    let calendar: Calendar
    let locale: Locale
    private let time: DateFormatter
    private let weekday: DateFormatter
    private let monthDay: DateFormatter
    private let monthDayYear: DateFormatter

    init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
        func formatter(_ template: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        }
        time = formatter("jmm")
        weekday = formatter("EEEE")
        monthDay = formatter("MMMd")
        monthDayYear = formatter("yMMMd")
    }

    func time(_ date: Date) -> String { time.string(from: date) }

    /// "Today", "Yesterday", a weekday within a week, else the date.
    func day(_ date: Date, now: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return HomeStrings.today }
        if days == 1 { return HomeStrings.yesterday }
        if days > 1, days < 7 { return weekday.string(from: date) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? monthDay.string(from: date) : monthDayYear.string(from: date)
    }
}

/// Every user-facing string of the renderer (Resources/Localizable.xcstrings).
/// Nonisolated: row bitmaps draw some of them off the main actor.
enum HomeStrings {
    static var today: String { String(localized: "separator.today", defaultValue: "Today", bundle: .module) }
    static var yesterday: String { String(localized: "separator.yesterday", defaultValue: "Yesterday", bundle: .module) }
    static var read: String { String(localized: "receipt.read", defaultValue: "Read", bundle: .module) }
    static var delivered: String { String(localized: "receipt.delivered", defaultValue: "Delivered", bundle: .module) }
    static var notDelivered: String { String(localized: "label.notDelivered", defaultValue: "Not Delivered", bundle: .module) }
    /// A send that got no answer after it reached the owner: it may be there.
    static var mayNotHaveBeenDelivered: String {
        String(localized: "label.mayNotHaveBeenDelivered", defaultValue: "May Not Have Been Delivered", bundle: .module)
    }
    static var unsentMine: String { String(localized: "row.unsent.mine", defaultValue: "You unsent a message", bundle: .module) }
    static var unsentTheirs: String {
        String(localized: "row.unsent.theirs", defaultValue: "A message was unsent", bundle: .module)
    }
    static var placeholder: String { String(localized: "compose.placeholder", defaultValue: "Message", bundle: .module) }
    static var fromMe: String { String(localized: "ax.from.me", defaultValue: "From you", bundle: .module) }
    static func from(_ name: String) -> String {
        String(format: String(localized: "ax.from.name", defaultValue: "From %@", bundle: .module), name)
    }
    static var typing: String { String(localized: "ax.typing", defaultValue: "Typing", bundle: .module) }
    static var composeLabel: String { String(localized: "ax.compose", defaultValue: "Message", bundle: .module) }
}
