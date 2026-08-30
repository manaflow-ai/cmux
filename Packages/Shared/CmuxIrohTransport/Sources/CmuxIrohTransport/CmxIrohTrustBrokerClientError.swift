public import CMUXMobileCore

/// Failures at the authenticated HTTP trust-broker boundary.
public enum CmxIrohTrustBrokerClientError:
    CmxRetryAfterProviding,
    Equatable,
    Sendable
{
    /// The authenticated broker could not be reached through the current network.
    case connectivity
    case invalidBaseURL
    case missingAuthentication
    case invalidAuthentication
    case nonHTTPResponse
    /// The broker rejected a request and supplied a bounded retry floor.
    case rateLimited(code: String?, retryAfterSeconds: Int)
    case rejected(statusCode: Int, code: String?)
    case invalidResponse

    /// Whether an inconclusive refresh may preserve already-verified state.
    ///
    /// This never admits a new peer. Callers may retain only state whose own
    /// signed lease or policy expiry remains authoritative.
    static func preservesVerifiedStateDuringRefresh(_ error: any Error) -> Bool {
        if let recovery = error as? CmxIrohBrokerTokenRecoveryError {
            return recovery == .transient
        }
        if (error as? any CmxRetryAfterProviding)?.retryAfterSeconds != nil {
            return true
        }
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity:
            return true
        case .rateLimited:
            return true
        case let .rejected(statusCode, _):
            // A 401 here already survived the
            // broker client's single force-refresh retry, so it is a session
            // transition still settling (rotation race, locked token store) or
            // a server-side availability condition — not a trust change. The
            // existing state remains bounded by its signed expiry; tearing it
            // down buys nothing and turns a seconds-long auth blip into a full
            // endpoint or session rebuild. A genuinely dead session clears
            // auth state through the coordinator, which stops the runtime
            // through the lifecycle owner instead.
            return statusCode == 401
                || statusCode == 408
                || statusCode == 425
                || statusCode == 429
                || (500...599).contains(statusCode)
        case .invalidBaseURL,
             .missingAuthentication,
             .invalidAuthentication,
             .nonHTTPResponse,
             .invalidResponse:
            return false
        }
    }

    /// Accepts only failures that are safe to retry before any binding is trusted.
    static func retriesInitialActivation(_ error: any Error) -> Bool {
        if let recovery = error as? CmxIrohBrokerTokenRecoveryError {
            return recovery == .transient
        }
        if (error as? any CmxRetryAfterProviding)?.retryAfterSeconds != nil {
            return true
        }
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity, .rateLimited:
            return true
        case let .rejected(statusCode, _):
            // A server failure cannot establish trust, so retrying the request
            // is safe while the lifecycle-owned start task remains current.
            // An authentication rejection cannot establish initial trust. It
            // must return to the auth lifecycle instead of retrying forever.
            return statusCode == 408
                || statusCode == 425
                || statusCode == 429
                || (500...599).contains(statusCode)
        case .invalidBaseURL,
             .missingAuthentication,
             .invalidAuthentication,
             .nonHTTPResponse,
             .invalidResponse:
            return false
        }
    }

    /// The validated server retry floor, when present.
    public var retryAfterSeconds: Int? {
        guard case let .rateLimited(_, retryAfterSeconds) = self else { return nil }
        return retryAfterSeconds
    }
}
