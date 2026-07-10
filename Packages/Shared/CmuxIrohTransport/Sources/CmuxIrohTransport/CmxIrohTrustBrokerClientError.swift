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
}
