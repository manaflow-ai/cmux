import Foundation

/// The `clock` data key custom sidebars read for live time.
///
/// The clock is the only part of a custom sidebar's data context that changes
/// on its own. Hosts build the rest of the context from workspace state and
/// refresh it when that state changes; the clock is merged in separately so a
/// sidebar that never reads it never re-renders just because a second passed.
public enum CustomSidebarClock {
    /// The data context key holding the clock object.
    public static let dataKey = "clock"

    /// The clock object for `now`: `time` (`HH:mm:ss`), `hour`, `minute`,
    /// `second`, `weekday` and `epoch` (whole seconds since 1970).
    public static func value(at now: Date, calendar: Calendar = .current) -> SwiftValue {
        let components = calendar.dateComponents([.hour, .minute, .second, .weekday], from: now)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        return .object([
            "time": .string(String(format: "%02d:%02d:%02d", hour, minute, second)),
            "hour": .int(hour),
            "minute": .int(minute),
            "second": .int(second),
            "weekday": .int(components.weekday ?? 0),
            "epoch": .int(Int(now.timeIntervalSince1970)),
        ])
    }

    /// Returns `context` with its `clock` key set to the clock at `now`.
    public static func dataContext(
        _ context: [String: SwiftValue],
        at now: Date,
        calendar: Calendar = .current
    ) -> [String: SwiftValue] {
        var context = context
        context[dataKey] = value(at: now, calendar: calendar)
        return context
    }

    /// Whether a sidebar program may read the clock, so its host has to tick
    /// every second.
    ///
    /// A plain substring test: sidebars reach the clock only through the
    /// `clock` name (`data.clock()` in JS, `clock.time` in interpreted
    /// Swift), and a false positive (the word in a comment or a label) only
    /// costs the old once-a-second refresh, never a stale clock.
    public static func sourceReadsClock(_ source: String) -> Bool {
        source.contains(dataKey)
    }
}
