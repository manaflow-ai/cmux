public import Foundation

/// How often a shuffled background turns to its next picture (`appearance.backgroundRotation`),
/// like macOS's rotating wallpaper. Consecutive periods step through the pictures by a stride that
/// shares no factor with their count, so each shows once before any repeats and neighbours land
/// far apart.
public nonisolated enum BackdropRotation: String, CaseIterable, Sendable {
    case quarterHour = "15m"
    case hourly
    case daily

    /// Unset: once a day, as Shuffle Daily always turned.
    public static let defaultRotation = BackdropRotation.daily

    /// The length of one period for the clock-aligned intervals.
    private var seconds: Double { self == .hourly ? 3_600 : 900 }

    /// The count of the period `date` falls in, in `calendar`'s time zone: the local day's number
    /// for ``daily`` (``BackdropArt/dayNumber(of:calendar:)``), else local clock periods.
    public func period(of date: Date, calendar: Calendar) -> Int {
        switch self {
        case .daily:
            return BackdropArt.dayNumber(of: date, calendar: calendar)
        case .hourly, .quarterHour:
            let local = date.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: date))
            return Int((local / seconds).rounded(.down))
        }
    }

    /// When the period after `date`'s starts: the next local midnight, hour or quarter hour.
    public func nextTurn(after date: Date, calendar: Calendar) -> Date {
        switch self {
        case .daily:
            return BackdropArt.nextDay(after: date, calendar: calendar)
        case .hourly, .quarterHour:
            let offset = Double(calendar.timeZone.secondsFromGMT(for: date))
            let next = ((date.timeIntervalSince1970 + offset) / seconds).rounded(.down) * seconds + seconds
            return Date(timeIntervalSince1970: next - offset)
        }
    }

    /// Which of `count` pictures shows at `date`; nil when there are none.
    public func index(count: Int, on date: Date, calendar: Calendar) -> Int? {
        guard count > 0 else { return nil }
        let period = (self.period(of: date, calendar: calendar) % count + count) % count
        return period * BackdropArt.dailyStride(count: count) % count
    }
}

extension BackdropArt {
    /// The painting of ``dailyRotation`` that shows at `date` when Shuffle turns `every` period.
    public nonisolated static func shuffled(on date: Date, every rotation: BackdropRotation,
                                            calendar: Calendar = .current) -> BackdropArt {
        let works = dailyRotation
        return works[rotation.index(count: works.count, on: date, calendar: calendar) ?? 0]
    }
}
