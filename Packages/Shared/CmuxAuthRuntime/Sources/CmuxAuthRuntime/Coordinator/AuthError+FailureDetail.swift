import Foundation
import StackAuth

/// The one-line failure detail a sign-in error screen shows and copies.
///
/// The line names what failed (error code, HTTP status, the sign-in service's
/// request ID) so a user can report it. It never includes tokens, URLs, or
/// server message bodies.
extension AuthError {
    /// Detail line for a raw error from a sign-in or session call.
    public static func failureDetail(for error: any Error) -> String {
        if let authError = error as? AuthError {
            return authError.failureDetail
        }
        if let stackError = error as? any StackAuthErrorProtocol {
            var parts = [stackError.code.uppercased()]
            if let status = stackError.details?["httpStatus"] as? Int {
                parts.append("HTTP \(status)")
            }
            if let requestID = stackError.details?["requestId"] as? String, !requestID.isEmpty {
                parts.append("Request ID \(requestID)")
            }
            return parts.joined(separator: " · ")
        }
        if let urlError = error as? URLError {
            return "URL_ERROR \(urlError.code.rawValue)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    /// Detail line for this display-safe error.
    public var failureDetail: String {
        switch self {
        case .offline: return "OFFLINE"
        case .networkError: return "NETWORK_ERROR"
        case .timedOut: return "TIMED_OUT"
        case let .serverError(status, code):
            return status > 0 ? "\(code.uppercased()) · HTTP \(status)" : code.uppercased()
        case .invalidCode: return "INVALID_CODE"
        case .invalidCallback: return "INVALID_CALLBACK"
        case .browserSignInFailed: return "BROWSER_SIGN_IN_FAILED"
        case .unauthorized: return "UNAUTHORIZED"
        case .authFailure: return "AUTH_FAILURE"
        case .cancelled: return "CANCELLED"
        case .rateLimited: return "RATE_LIMITED"
        }
    }
}
