public import Foundation

/// Pure formatting for the two notification fields the control protocol renders
/// on the app side: the ISO-8601 `created_at` timestamp and the percent-escaped
/// trailing field used by the V1 `list_notifications` line format.
///
/// This is the single source of truth for both shapes, replacing the former
/// file-private `TerminalController.notificationCreatedAtString` /
/// `notificationListTrailingField` statics (and the duplicate
/// `notificationCreatedAtISO8601` the notification conformance carried). The app
/// target forwards to these so the package owns the byte shape and never
/// diverges across call sites.
///
/// A pure value type with no stored state; every method is a deterministic
/// transform of its input, so a single shared instance (or any fresh one) is
/// equivalent. The caller provides isolation.
public struct ControlNotificationFieldFormatter: Sendable {
    /// Creates a formatter.
    public init() {}

    /// Renders a notification's creation timestamp as ISO-8601, byte-identical
    /// to the legacy `notificationCreatedAtString`
    /// (`ISO8601DateFormatter` with `.withInternetDateTime`, GMT).
    ///
    /// - Parameter date: The notification creation date.
    /// - Returns: The ISO-8601 rendering in GMT.
    public func createdAtISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Percent-escapes a value for the trailing `pct:`-prefixed field of the
    /// V1 `list_notifications` pipe-delimited line, byte-identical to the legacy
    /// `notificationListTrailingField` (escapes `%`, `|`, newline, carriage
    /// return in that order so the `|` separators and line breaks survive).
    ///
    /// - Parameter value: The raw field value (typically the tab title).
    /// - Returns: The `pct:`-prefixed, percent-escaped field.
    public func listTrailingField(_ value: String) -> String {
        "pct:" + value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
    }
}
