public import Foundation

/// A daily window (local time) in which banners and sounds stay quiet.
public nonisolated struct QuietHours: Hashable, Sendable, Codable {
    /// Minutes after midnight.
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Parses `"HH:MM"`.
    public static func minutes(_ text: String) -> Int? {
        SettingsRust.answer("notifications.quiet_minutes", ["text": .string(text)])["minutes"]?.intValue
    }

    /// True when `minuteOfDay` lies in the window; a window may wrap past midnight.
    public func contains(minuteOfDay: Int) -> Bool {
        SettingsRust.answer("notifications.quiet_contains", [
            "quietHours": SettingsRust.json(self), "minuteOfDay": JSONValue(minuteOfDay),
        ])["contains"]?.boolValue ?? false
    }
}
