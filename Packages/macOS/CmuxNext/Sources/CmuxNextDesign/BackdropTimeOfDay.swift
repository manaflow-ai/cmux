public import Foundation

/// A background that changes through the day (`appearance.backgroundSchedule`): each entry's
/// picture shows from its time until the next entry's. A time is a local clock time (`07:00`) or a
/// sun event with an optional offset (`sunset-30m`, `sunrise+1h`). Now's picture is the entry whose
/// time today is the latest at or before now; before the first, yesterday's last. A sun event that
/// does not happen on a day (polar day or night) is skipped that day. A clock time a spring-forward
/// gap skips fires at the first instant after the gap; one a fall-back repeats fires the first time.
public nonisolated struct BackdropTimeOfDay: Equatable, Sendable {
    /// When an entry starts.
    public enum When: Hashable, Sendable {
        /// Minutes after local midnight.
        case clock(minutes: Int)
        /// A sun event, moved by `offset` seconds.
        case sun(SunEvent, offset: TimeInterval)
    }

    public enum SunEvent: String, CaseIterable, Sendable {
        case dawn, sunrise, noon, sunset, dusk
    }

    /// The entries by when, each with its value (a background id).
    public let entries: [(when: When, value: String)]

    public init(entries: [(when: When, value: String)]) {
        // A stable order (by when, then value), so two readings of one object compare equal.
        self.entries = entries.sorted { ("\($0.when)", $0.value) < ("\($1.when)", $1.value) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.map { $0.when } == rhs.entries.map { $0.when } && lhs.entries.map { $0.value } == rhs.entries.map { $0.value }
    }

    /// Whether any entry needs the sun (and so a location).
    public var usesSun: Bool { entries.contains { if case .sun = $0.when { true } else { false } } }

    /// Reads one schedule key: `H:MM` or `HH:MM` (24 h), or `dawn` | `sunrise` | `noon` | `sunset` |
    /// `dusk` with an optional `+N` / `-N` offset in `m` or `h` (`sunset-30m`, `dusk+90m`, `sunrise+1h`), as written.
    public static func when(_ text: String) -> When? {
        if let colon = text.firstIndex(of: ":") {
            let hour = text[..<colon], minute = text[text.index(after: colon)...]
            guard (1...2).contains(hour.count), minute.count == 2, Self.digits(hour), Self.digits(minute),
                  let h = Int(hour), let m = Int(minute), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
            return .clock(minutes: h * 60 + m)
        }
        let sign = text.firstIndex { $0 == "+" || $0 == "-" } ?? text.endIndex
        guard let event = SunEvent(rawValue: String(text[..<sign])) else { return nil }
        guard sign != text.endIndex else { return .sun(event, offset: 0) }
        var amount = text[text.index(after: sign)...]
        guard let unit = amount.popLast(), unit == "m" || unit == "h", !amount.isEmpty, Self.digits(amount),
              let count = Int(amount), count <= (unit == "m" ? 1_440 : 24) else { return nil }
        let seconds = TimeInterval(count) * (unit == "h" ? 3_600 : 60)
        return .sun(event, offset: text[sign] == "-" ? -seconds : seconds)
    }

    private static func digits(_ text: Substring) -> Bool { text.allSatisfy { $0.isASCII && $0.isWholeNumber } }

    /// Reads a schedule object: every key must be a valid `when` and every value a string
    /// `isValue` accepts; nil otherwise.
    public static func parse(_ members: [String: String], isValue: (String) -> Bool) -> BackdropTimeOfDay? {
        var entries: [(when: When, value: String)] = []
        for (key, value) in members {
            guard let start = Self.when(key), isValue(value) else { return nil }
            entries.append((when: start, value: value))
        }
        return BackdropTimeOfDay(entries: entries)
    }

    /// The entry shown at `date` and when the next one starts (nil: none within a week).
    public func resolve(at date: Date, location: BackdropLocation?, calendar: Calendar) -> (value: String?, next: Date?) {
        guard !entries.isEmpty else { return (nil, nil) }
        // Occurrences over a week around `date`, so a day whose sun events are all skipped (polar
        // night) and an offset that crosses midnight both find their neighbours.
        var times: [(date: Date, value: String)] = []
        for day in -3...3 {
            guard let other = calendar.date(byAdding: .day, value: day, to: date) else { continue }
            let start = calendar.startOfDay(for: other)
            let sun = usesSun ? location.map { $0.sunEvents(on: start, calendar: calendar) } : nil
            for entry in entries {
                if let time = occurrence(entry.when, dayStart: start, sun: sun, calendar: calendar) {
                    times.append((time, entry.value))
                }
            }
        }
        times.sort { $0.date < $1.date }
        let shown = times.last { $0.date <= date }?.value
        return (shown, times.first { $0.date > date }?.date)
    }

    /// When `when` happens on the local day starting at `dayStart`; nil for a sun event that day lacks.
    func occurrence(_ when: When, dayStart: Date, sun: SunEvents?, calendar: Calendar) -> Date? {
        switch when {
        case .clock(let minutes):
            return Self.wallTime(minutes * 60, dayStart: dayStart, timeZone: calendar.timeZone)
        case .sun(let event, let offset):
            guard let sun else { return nil }
            let time: Date? = switch event {
            case .dawn: sun.dawn
            case .sunrise: sun.sunrise
            case .noon: sun.noon
            case .sunset: sun.sunset
            case .dusk: sun.dusk
            }
            return time?.addingTimeInterval(offset)
        }
    }

    /// The instant the local clock reads `seconds` past midnight on the day starting at `dayStart`:
    /// its first occurrence when a fall-back repeats it, the end of the gap when a spring-forward skips it.
    static func wallTime(_ seconds: Int, dayStart: Date, timeZone: TimeZone) -> Date {
        // The day's wall clock as if it were UTC, then each offset the zone uses around it.
        let wallMidnight = dayStart.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: dayStart))
        let wall = wallMidnight + Double(seconds)
        let offsets = Set([timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall - 86_400)),
                           timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall)),
                           timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall + 86_400))])
        let candidates = offsets.map { Date(timeIntervalSince1970: wall - Double($0)) }
        let valid = candidates.filter { Double(timeZone.secondsFromGMT(for: $0)) + $0.timeIntervalSince1970 == wall }
        if let first = valid.min() { return first }
        // In a gap: the transition that skipped it.
        let earliest = candidates.min() ?? Date(timeIntervalSince1970: wall)
        return timeZone.nextDaylightSavingTimeTransition(after: earliest.addingTimeInterval(-1)) ?? earliest
    }
}
