public import Foundation

/// Errors the connector can classify without exposing response text or tokens.
public enum CloudGitHubConnectorClientError: Error, Equatable, Sendable {
    case privateRepository
    case notFound
    case offline
    case unauthorized
    case unavailable
    case requestFailed

    /// Maps an HTTP response or transport error to the copy the UI needs.
    public static func classify(status: Int? = nil, code: String? = nil, transport: Error? = nil) -> Self {
        if let transport as URLError,
           transport.code == .notConnectedToInternet || transport.code == .networkConnectionLost || transport.code == .cannotFindHost {
            return .offline
        }
        switch code?.lowercased() {
        case "private", "forbidden", "private_repository": return .privateRepository
        case "not_found", "not-found": return .notFound
        case "unauthorized", "needs_auth": return .unauthorized
        case "unavailable", "not_configured": return .unavailable
        default: break
        }
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        default: return .requestFailed
        }
    }
}

