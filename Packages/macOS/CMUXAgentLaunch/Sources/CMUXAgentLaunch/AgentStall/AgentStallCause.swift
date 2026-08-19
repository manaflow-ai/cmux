import Foundation

/// The stable cause classes emitted by the managed-agent stall classifier.
public enum AgentStallCause: String, Codable, CaseIterable, Equatable, Sendable {
    /// A connection reset, refusal, timeout, or server-side 5xx response.
    case transientTransport
    /// A provider rate-limit response.
    case rateLimit
    /// A provider overload or temporary-unavailability response.
    case overload
    /// A provider safety policy refused the requested content.
    case safeguardRefusal
    /// The account has no remaining credits or usage quota.
    case quotaExhausted
    /// Credentials or the provider session are no longer valid.
    case authenticationExpired

    /// The action policy associated with the cause.
    public var disposition: AgentStallDisposition {
        switch self {
        case .transientTransport, .rateLimit, .overload:
            return .retryable
        case .safeguardRefusal, .quotaExhausted, .authenticationExpired:
            return .humanRequired
        }
    }
}
