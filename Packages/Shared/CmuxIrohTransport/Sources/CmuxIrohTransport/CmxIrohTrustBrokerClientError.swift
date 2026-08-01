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

    static func preservesVerifiedPolicyDuringRefresh(_ error: any Error) -> Bool {
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
            // 401/403: an unauthorized rejection here already survived the
            // broker client's single force-refresh retry, so it is a session
            // transition still settling (rotation race, locked token store) or
            // a server-side availability condition — not a trust change. The
            // cached policy was verified when stored; tearing the runtime down
            // buys nothing and turns a seconds-long auth blip into a full
            // endpoint rebuild. A genuinely dead session clears auth state
            // through the coordinator, which stops the runtime through the
            // lifecycle owner instead.
            return statusCode == 401
                || statusCode == 403
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
            // 401 joins the retriable set: it already survived the broker
            // client's single force-refresh retry, so it is a session
            // transition still settling; a dead session exits through the auth
            // coordinator's state clear, not through this loop.
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

    /// Availability-only failures: the broker could not answer, as opposed to
    /// an authenticated denial.
    ///
    /// Dial-time cached-policy fallbacks key on this set so an authoritative
    /// rejection — 401/403 INCLUDED — never unlocks cached grants or the
    /// offline policy store: a revoked account or binding must stop dialing at
    /// the next dial, not at grant expiry. Contrast with
    /// ``preservesVerifiedPolicyDuringRefresh(_:)``, which additionally
    /// accepts auth rejections because keeping already-verified IN-MEMORY
    /// state during a refresh grants nothing new.
    static func isAvailabilityFailure(_ error: any Error) -> Bool {
        if (error as? any CmxRetryAfterProviding)?.retryAfterSeconds != nil {
            return true
        }
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity, .rateLimited:
            return true
        case let .rejected(statusCode, _):
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
