/// Why a sign-in attempt failed. Never the raw error text.
public enum SignInFailureReason: String, Sendable, CaseIterable {
    case offline
    case network
    case timedOut = "timed_out"
    case server
    case invalidLink = "invalid_link"
    case browserUnavailable = "browser_unavailable"
    case unauthorized
    case rejected
    case cancelled
    case rateLimited = "rate_limited"
}
