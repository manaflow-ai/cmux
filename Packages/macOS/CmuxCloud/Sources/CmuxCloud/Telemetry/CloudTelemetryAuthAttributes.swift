import Foundation

/// The fields of a sign-in service rate-limit record. Exported as the span
/// `cmux.auth.<event>` with `cmux.auth.*` attributes. Holds no account,
/// token, email or query data.
public struct CloudTelemetryAuthAttributes: Codable, Sendable, Equatable {
    public enum Event: String, Codable, Sendable {
        case stackRateLimited = "stack_rate_limited"
        case stackRateLimitRecovered = "stack_rate_limit_recovered"
    }

    public let event: Event
    /// `sign_in_completion`, `token_refresh`, `session_check` or `other`.
    public let phase: String
    public var retryAfterS: Int?
    public var backoffS: Int?
    /// `json`, `html` or `other`.
    public var bodyKind: String?
    /// The request path with ids replaced by `ID`.
    public var endpoint: String?
    public var limitedForS: Int?

    public init(
        event: Event,
        phase: String,
        retryAfterS: Int? = nil,
        backoffS: Int? = nil,
        bodyKind: String? = nil,
        endpoint: String? = nil,
        limitedForS: Int? = nil
    ) {
        self.event = event
        self.phase = phase
        self.retryAfterS = retryAfterS
        self.backoffS = backoffS
        self.bodyKind = bodyKind
        self.endpoint = endpoint
        self.limitedForS = limitedForS
    }
}
