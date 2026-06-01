import CMUXMobileCore
import Foundation

public enum AuthError: Error, LocalizedError {
    case offline
    case networkError
    case serverError(Int, String)
    case invalidCode
    case unauthorized
    case authFailure
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .offline:
            return L10n.string(
                "auth.error.offline",
                defaultValue: "No internet connection. Connect to Wi-Fi or cellular and try again."
            )
        case .networkError:
            return L10n.string("auth.error.network_error", defaultValue: "Network error. Please check your connection.")
        case .serverError:
            return L10n.string("auth.error.server_error", defaultValue: "Something went wrong. Please try again.")
        case .invalidCode:
            return L10n.string("auth.error.invalid_code_short", defaultValue: "Invalid code. Please try again.")
        case .unauthorized:
            return L10n.string("auth.error.unauthorized", defaultValue: "Session expired. Please sign in again.")
        case .authFailure:
            return L10n.string("auth.error.wrong_password", defaultValue: "Incorrect email or password.")
        case .cancelled:
            return nil
        }
    }
}
