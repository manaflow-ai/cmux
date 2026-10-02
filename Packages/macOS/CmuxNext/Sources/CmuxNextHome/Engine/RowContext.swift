import Foundation

/// Everything row derivation reads besides the messages: who I am, the
/// geometry, the clock and the receipt inputs. Built on the main actor.
struct RowContext {
    var meID: String
    var geometry: TranscriptGeometry
    var now: Date
    var readThrough: Int?
    var typing: Bool
    var strings: RowStrings
    var measurer: Measurer
}

/// Localized row labels and the separator date formatting.
struct RowStrings {
    var retracted: String
    var sending: String
    var notDelivered: String
    var read: String
    var delivered: String
    var today: String
    var yesterday: String
    var workStatus: (HomeWorkStatus) -> String = { $0.rawValue }
    private let time: DateFormatter
    private let day: DateFormatter
    private let dayYear: DateFormatter

    init(retracted: String, sending: String, notDelivered: String, read: String, delivered: String, today: String,
         yesterday: String, locale: Locale = .autoupdatingCurrent) {
        self.retracted = retracted
        self.sending = sending
        self.notDelivered = notDelivered
        self.read = read
        self.delivered = delivered
        self.today = today
        self.yesterday = yesterday
        time = DateFormatter()
        time.locale = locale
        time.dateStyle = .none
        time.timeStyle = .short
        day = DateFormatter()
        day.locale = locale
        day.setLocalizedDateFormatFromTemplate("EEEMMMd")
        dayYear = DateFormatter()
        dayYear.locale = locale
        dayYear.setLocalizedDateFormatFromTemplate("yMMMd")
    }

    static func localized() -> RowStrings {
        var strings = RowStrings(retracted: HomeStrings.retracted, sending: HomeStrings.sending,
                                 notDelivered: HomeStrings.notDelivered, read: HomeStrings.read,
                                 delivered: HomeStrings.delivered, today: HomeStrings.today,
                                 yesterday: HomeStrings.yesterday)
        let labels = Dictionary(uniqueKeysWithValues: [HomeWorkStatus.running, .done, .failed, .waiting].map {
            ($0, HomeStrings.workStatus($0))
        })
        strings.workStatus = { labels[$0] ?? $0.rawValue }
        return strings
    }

    func timeString(_ date: Date) -> String { time.string(from: date) }

    /// The separator's bold day part: Today, Yesterday, a weekday date, or a full date in another year.
    func dayString(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return yesterday }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return day.string(from: date) }
        return dayYear.string(from: date)
    }
}
