/// Classified failures at the authenticated HTTP trust-broker boundary.
///
/// The five cases are the caller-facing taxonomy (design principle 6:
/// transient / signed-out / denied are distinct end to end):
///
/// - `connectivity`: the broker could not be consulted RIGHT NOW (network
///   failure, token store mid-transition, or a transient 408/425/5xx server
///   condition). Retry and offline-cache fallback policies apply.
/// - `unauthorized`: definitively signed out, or a 401 that survived the
///   one-shot credential recovery. Returns to the auth lifecycle. It never
///   clears cached transport state by itself.
/// - `denied`: the broker answered and refused (403 and other rejections).
///   Fail closed; no cache fallback.
/// - `serverRateLimited`: a 429 floor; `retryAfter` carries the validated
///   Retry-After directive for the account-scoped cooldown ledger.
/// - `protocolError`: the response violated the fixed wire contract
///   (non-HTTP, undecodable, or a security invariant failed). Fail closed.
public enum PeerBrokerError: Error, Equatable, Sendable {
    case connectivity
    case unauthorized
    case denied(statusCode: Int, code: String?)
    case serverRateLimited(retryAfter: Duration?)
    case protocolError

    /// The validated server retry floor, when the broker supplied one.
    public var retryAfter: Duration? {
        guard case let .serverRateLimited(retryAfter) = self else { return nil }
        return retryAfter
    }

    /// Whether the offline grant cache may be consulted after this failure.
    ///
    /// Only broker unreachability qualifies. Authentication, denial, rate
    /// limiting, and protocol violations all fail closed.
    public var allowsOfflineGrantFallback: Bool {
        self == .connectivity
    }

    /// Whether a retry (bounded by the caller's ladder) can plausibly succeed
    /// without any credential or trust change.
    public var isTransient: Bool {
        switch self {
        case .connectivity, .serverRateLimited:
            return true
        case let .denied(statusCode, _):
            return statusCode == 408
                || statusCode == 425
                || (500 ... 599).contains(statusCode)
        case .unauthorized, .protocolError:
            return false
        }
    }
}
