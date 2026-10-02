import Foundation

/// Parses the ISO 8601 timestamps mobile RPC payloads carry, with or without
/// fractional seconds. A bare `ISO8601DateFormatter` accepts whole seconds
/// only, so `2026-09-30T22:44:53.481Z` would otherwise read as malformed.
enum MobileRPCISO8601Date {
    // `ISO8601DateFormatter` is documented thread-safe; the annotations only
    // silence the strict-concurrency diagnostic for these immutable statics.
    nonisolated(unsafe) private static let fractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeSeconds = ISO8601DateFormatter()

    /// - Parameter raw: The wire timestamp.
    /// - Returns: The date, or `nil` when `raw` isn't an ISO 8601 date-time.
    static func parse(_ raw: String) -> Date? {
        fractionalSeconds.date(from: raw) ?? wholeSeconds.date(from: raw)
    }
}
