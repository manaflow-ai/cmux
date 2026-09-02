public import Foundation

/// Failures of the phone's `/api/vm` client.
public enum CloudAPIError: Error, Equatable, Sendable {
    /// No Stack session tokens were available.
    case notSignedIn
    /// The base URL or path did not form a URL.
    case invalidURL(String)
    /// The server answered with a non-2xx status; `message` is its JSON
    /// `message`/`error` when present.
    case httpStatus(Int, message: String?)
    /// The response body did not have the expected shape.
    case malformedResponse(String)

    /// Whether the server rejected the session, so the user must sign in again.
    public var isUnauthorized: Bool {
        if case .httpStatus(401, _) = self { return true }
        return false
    }
}
