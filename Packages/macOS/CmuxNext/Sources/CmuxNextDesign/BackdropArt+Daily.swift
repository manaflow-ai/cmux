public import Foundation

/// Shuffle Daily (cx-t2x.5): `appearance.background: "daily"` shows one work a local day.
extension BackdropArt {
    /// The work for `date`'s local day in `calendar`'s time zone, from ``dailyRotation``. Consecutive
    /// days step through it by a stride that shares no factor with its size, so every work shows once
    /// before any repeats and neighbouring days land far apart in the set (and its collections).
    public nonisolated static func daily(on date: Date, calendar: Calendar = .current) -> BackdropArt {
        let works = dailyRotation
        let index = (dayNumber(of: date, calendar: calendar) % works.count) * dailyStride(count: works.count) % works.count
        return works[index]
    }

    /// The count of `date`'s local day: its Gregorian date in `calendar`'s time zone, counted in UTC.
    /// `ordinality(of: .day, in: .era)` steps every 86,400 s from the era's start, a midnight in the
    /// zone's 1 AD local mean time, so outside UTC it turns off local midnight (London in summer time
    /// at 01:01:15), after ``nextDay(after:calendar:)`` re-picks the work. In UTC the count is the
    /// same as that ordinality, so each day keeps the work it always had there.
    nonisolated static func dayNumber(of date: Date, calendar: Calendar) -> Int {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = calendar.timeZone
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        var day = local.dateComponents([.era, .year, .month, .day], from: date)
        day.hour = 12
        guard let noon = utc.date(from: day) else { return 0 }
        return utc.ordinality(of: .day, in: .era, for: noon) ?? 0
    }

    /// The start of the local day after `date`, when ``daily(on:calendar:)`` turns to the next work.
    public nonisolated static func nextDay(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    nonisolated static func dailyStride(count: Int) -> Int {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        return [97, 89, 83, 79, 73, 71, 67, 61, 59, 53].first { gcd($0, count) == 1 } ?? 1
    }
}
