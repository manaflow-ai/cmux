public import Foundation

/// Failures of the phone's `/api/vm` client.
public enum CloudAPIError: Error, Equatable, Sendable {
    /// No Stack session tokens were available.
    case notSignedIn
    /// The base URL or path did not form a URL.
    case invalidURL(String)
    /// The server answered with a non-2xx status. `message` and `action` are
    /// copied from the server's safe JSON error envelope so the UI can tell
    /// the user how to recover (for example, enable Pro or choose base).
    case httpStatus(Int, message: String?, action: String?)
    /// The response body did not have the expected shape.
    case malformedResponse(String)

    /// Whether the server rejected the session, so the user must sign in again.
    public var isUnauthorized: Bool {
        if case .httpStatus(401, _, _) = self { return true }
        return false
    }
}
