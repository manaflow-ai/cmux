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

    /// Parses `"HH:MM"` (Rust `notifications.quiet_minutes`).
    public static func minutes(_ text: String) -> Int? {
        SettingsRust.answer("notifications.quiet_minutes", ["text": .string(text)])["minutes"]?.intValue
    }

    /// True when `minuteOfDay` lies in the window; a window may wrap past midnight
    /// (Rust `notifications.quiet_contains`).
    public func contains(minuteOfDay: Int) -> Bool {
        let request: JSONValue = [
            "quietHours": ["start": JSONValue(start), "end": JSONValue(end)],
            "minuteOfDay": JSONValue(minuteOfDay),
        ]
        return SettingsRust.answer("notifications.quiet_contains", request)["contains"]?.boolValue ?? false
    }
}
