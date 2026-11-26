public import Foundation
import CmuxNextWindowRules

/// A daily window (local time) in which banners and sounds stay quiet.
public nonisolated struct QuietHours: Hashable, Sendable {
    /// Minutes after midnight.
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Parses `"HH:MM"` (cmux-window-rules `window_notifications_quiet_minutes`); nil when it does
    /// not parse or the FFI does not answer.
    public static func minutes(_ text: String) -> Int? {
        struct Request: Encodable { var text: String }
        struct Reply: Decodable { var minutes: Int? }
        return WindowRules().call("window_notifications_quiet_minutes", Request(text: text), as: Reply.self)?.minutes
    }

    /// True when `minuteOfDay` lies in the window; a window may wrap past midnight.
    public func contains(minuteOfDay: Int) -> Bool {
        if start == end { return false }
        return start < end ? (start..<end).contains(minuteOfDay) : minuteOfDay >= start || minuteOfDay < end
    }
}
