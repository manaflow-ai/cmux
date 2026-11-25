import Foundation

extension Date {
    /// An engine date (optchat-chief `now_rfc3339`: `2026-11-06T16:02:11Z`, with or without fractional seconds).
    nonisolated init?(chiefRFC3339 text: String) {
        if let date = try? Date.ISO8601FormatStyle().parse(text) {
            self = date
        } else if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            self = date
        } else {
            return nil
        }
    }
}
