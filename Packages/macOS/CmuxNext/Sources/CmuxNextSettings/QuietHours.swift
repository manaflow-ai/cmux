public import Foundation

/// A daily window (local time) in which banners and sounds stay quiet.
public nonisolated struct QuietHours: Hashable, Sendable {
    /// Minutes after midnight.
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Parses `"HH:MM"`.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// True when `minuteOfDay` lies in the window; a window may wrap past midnight.
    public func contains(minuteOfDay: Int) -> Bool {
        if start == end { return false }
        return start < end ? (start..<end).contains(minuteOfDay) : minuteOfDay >= start || minuteOfDay < end
    }
}
