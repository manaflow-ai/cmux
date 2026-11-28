import Foundation
import StackAuth

/// A 429 answer from the sign-in service, recognized on whatever error a
/// call surfaced, plus the bounded retry policy the sign-in flow uses.
///
/// The service's edge can answer 429 with an HTML page instead of a JSON
/// error; the SDK classifies by status, so both shapes arrive here as the
/// `RATE_LIMITED` code, with any `Retry-After` in the error details.
public struct AuthRateLimit: Sendable, Equatable {
    /// The server's `Retry-After`, when it sent one.
    public let retryAfter: Duration?
    /// The answered path with ids replaced by `ID`, for telemetry.
    public let endpoint: String
    /// `json`, `html` or `other`: whether the API or an edge page answered.
    public let bodyKind: String

    /// Recognizes a rate-limit error, or returns `nil` for any other error.
    /// - Parameter error: The error a sign-in or session call threw.
    public init?(error: any Error) {
        guard let stackError = error as? any StackAuthErrorProtocol else { return nil }
        switch stackError.code.uppercased() {
        case "RATE_LIMITED", "RATE_LIMIT":
            break
        default:
            return nil
        }
        endpoint = stackError.details?[StackAuthError.endpointKey] as? String ?? "/unknown"
        bodyKind = stackError.details?[StackAuthError.bodyKindKey] as? String ?? "other"
        if let seconds = stackError.details?[StackAuthError.retryAfterSecondsKey] as? TimeInterval,
           seconds.isFinite, seconds >= 0 {
            // A remote header: bound it before the Int64 conversion.
            retryAfter = .milliseconds(Int64(min(seconds, 86_400) * 1000))
        } else {
            retryAfter = nil
        }
    }

    /// Retries the sign-in flow makes after a 429 before it shows a failure.
    static let maximumRetries = 6

    /// Longest single wait. A larger `Retry-After` is clamped to this, so
    /// the pane never waits silently for many minutes.
    static let maximumDelay: Duration = .seconds(120)

    /// The wait before retry number `retry` (1-based).
    ///
    /// Honors `Retry-After` (clamped to 1 s...``maximumDelay``). Without it,
    /// the wait is exponential from 2 s, capped at 60 s, scaled by `jitter`
    /// (expected in 0.5...1.0) so many Macs behind one IP spread out.
    static func delay(retryAfter: Duration?, retry: Int, jitter: Double) -> Duration {
        if let retryAfter {
            return min(max(retryAfter, .seconds(1)), maximumDelay)
        }
        let exponent = Double(max(0, min(retry - 1, 5)))
        let base = min(2 * pow(2, exponent), 60)
        let scaled = base * min(max(jitter, 0.5), 1.0)
        return .milliseconds(Int64(scaled * 1000))
    }
}
