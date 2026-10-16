import Foundation

/// The Pro free trial an account is on, from the Cloud service's
/// `/api/billing/plan` `trial` object.
///
/// The service runs a trial on a limited allowance (one machine, a small
/// size and a small number of VM-hours) and names it Pro, never Go. Every
/// surface that names the plan says "Pro trial" and offers no upgrade while
/// the trial runs: full Pro starts when the trial converts.
public struct CmuxProTrial: Sendable, Equatable {
    /// When the trial ends, or `nil` when the service did not say.
    public let endsAt: Date?

    /// Creates a trial snapshot.
    ///
    /// - Parameter endsAt: When the trial ends, or `nil` when unknown.
    public init(endsAt: Date?) {
        self.endsAt = endsAt
    }

    /// Reads the `trial.endsAt` value of a plan response: an ISO 8601
    /// timestamp with or without fractional seconds. Anything else is unknown.
    ///
    /// - Parameter value: The raw `endsAt` string, or `nil`.
    /// - Returns: The parsed date, or `nil` when the value is absent or unreadable.
    public static func endDate(fromISO8601 value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
