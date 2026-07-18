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
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity:
            return true
        case .rateLimited:
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

    /// Accepts only failures that are safe to retry before any binding is trusted.
    static func retriesInitialActivation(_ error: any Error) -> Bool {
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity, .rateLimited:
            return true
        case let .rejected(statusCode, _):
            // A server failure cannot establish trust, so retrying the request
            // is safe while the lifecycle-owned start task remains current.
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
