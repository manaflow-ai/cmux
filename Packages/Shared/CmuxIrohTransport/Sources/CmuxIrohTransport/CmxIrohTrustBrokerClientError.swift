/// Failures at the authenticated HTTP trust-broker boundary.
public enum CmxIrohTrustBrokerClientError: Error, Equatable, Sendable {
    /// The authenticated broker could not be reached through the current network.
    case connectivity
    case invalidBaseURL
    case missingAuthentication
    case invalidAuthentication
    case nonHTTPResponse
    case rejected(statusCode: Int, code: String?)
    case invalidResponse

    static func preservesVerifiedPolicyDuringRefresh(_ error: any Error) -> Bool {
        guard let brokerError = error as? Self else { return false }
        switch brokerError {
        case .connectivity:
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
}
