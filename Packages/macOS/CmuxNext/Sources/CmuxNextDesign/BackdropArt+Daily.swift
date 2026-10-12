public import Foundation

/// Shuffle Daily (cx-t2x.5): `appearance.background: "daily"` shows one work a local day.
extension BackdropArt {
    /// The work for `date`'s local day. Consecutive days step through the set by a stride that
    /// shares no factor with its size, so every work shows once before any repeats and neighbouring
    /// days land far apart in the set (and its collections).
    public static func daily(on date: Date, calendar: Calendar = .current) -> BackdropArt {
        let works = allCases
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        let index = (day % works.count) * dailyStride(count: works.count) % works.count
        return works[index]
    }

    /// The start of the local day after `date`, when ``daily(on:calendar:)`` turns to the next work.
    public static func nextDay(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    static func dailyStride(count: Int) -> Int {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        return [97, 89, 83, 79, 73, 71, 67, 61, 59, 53].first { gcd($0, count) == 1 } ?? 1
    }
}
