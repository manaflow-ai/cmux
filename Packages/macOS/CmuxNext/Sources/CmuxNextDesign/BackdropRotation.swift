public import Foundation

/// How often a shuffled background turns to its next picture (`appearance.backgroundRotation`),
/// like macOS's rotating wallpaper: every 15 minutes, hour or day, or every N minutes (a number,
/// 1...1440). Unset is `BackdropSelectionSetting.rotationDefault` (daily,
/// schemas/settings/source/appearance.json). Consecutive periods step through the pictures by a stride that
/// shares no factor with their count, so each shows once before any repeats and neighbours land
/// far apart.
public nonisolated enum BackdropRotation: RawRepresentable, Hashable, Sendable {
    case quarterHour
    case hourly
    case daily
    /// Every this many minutes, on the local clock (periods counted from local midnight of 1970).
    case minutes(Int)

    /// The fixed choices, in the Settings order.
    public static let allCases: [BackdropRotation] = [.quarterHour, .hourly, .daily]

    /// The choice's stored string (`15m`, `hourly`, `daily`); a minute count as its number.
    public var rawValue: String {
        switch self {
        case .quarterHour: "15m"
        case .hourly: "hourly"
        case .daily: "daily"
        case .minutes(let count): String(count)
        }
    }

    /// A stored string: a choice, or a whole number of minutes from 1 to 1440.
    public init?(rawValue: String) {
        switch rawValue {
        case "15m": self = .quarterHour
        case "hourly": self = .hourly
        case "daily": self = .daily
        default:
            guard let count = Int(rawValue), (1...1_440).contains(count) else { return nil }
            self = .minutes(count)
        }
    }

    /// A stored number of minutes (1...1440, rounded to whole minutes).
    public init?(minutes: Double) {
        guard minutes.isFinite, (1...1_440).contains(minutes) else { return nil }
        self = .minutes(Int(minutes.rounded()))
    }

    /// The length of one period for the clock-aligned intervals.
    private var seconds: Double {
        switch self {
        case .hourly: 3_600
        case .quarterHour: 900
        case .minutes(let count): Double(max(count, 1)) * 60
        case .daily: 86_400
        }
    }

    /// The count of the period `date` falls in, in `calendar`'s time zone: the local day's number
    /// for ``daily`` (``BackdropArt/dayNumber(of:calendar:)``), else local clock periods.
    public func period(of date: Date, calendar: Calendar) -> Int {
        switch self {
        case .daily:
            return BackdropArt.dayNumber(of: date, calendar: calendar)
        case .hourly, .quarterHour, .minutes:
            let local = date.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: date))
            return Int((local / seconds).rounded(.down))
        }
    }

    /// When the period after `date`'s starts: the next local midnight, hour, quarter hour or N minutes.
    public func nextTurn(after date: Date, calendar: Calendar) -> Date {
        switch self {
        case .daily:
            return BackdropArt.nextDay(after: date, calendar: calendar)
        case .hourly, .quarterHour, .minutes:
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
