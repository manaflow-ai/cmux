import AuthenticationServices
import Foundation
import OSLog

enum AuthManagerError: LocalizedError, Equatable {
    case invalidCallback
    case missingAccessToken
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return String(
                localized: "settings.account.error.invalidCallback",
                defaultValue: "The sign-in callback was invalid."
            )
        case .missingAccessToken:
            return String(
                localized: "settings.account.error.missingAccessToken",
                defaultValue: "Account access token is unavailable."
            )
        case .missingRefreshToken:
            return String(
                localized: "settings.account.error.missingRefreshToken",
                defaultValue: "Account refresh token is unavailable."
            )
        }
    }
}

enum AuthSignInError: Equatable {
    case authManager(AuthManagerError)
    case message(String)

    var localizedMessage: String {
        switch self {
        case .authManager(let error):
            return error.errorDescription ?? Self.genericLocalizedMessage
        case .message:
            return Self.genericLocalizedMessage
        }
    }

    private static var genericLocalizedMessage: String {
        String(
            localized: "settings.account.error.signInFailed",
            defaultValue: "Sign in failed. Try again."
        )
    }
}

extension AuthManager {
    nonisolated static let authLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? AuthKeychainServiceName.stableFallback,
        category: "auth"
    )

    static func signInError(from error: Error) -> AuthSignInError {
        if let authError = error as? AuthManagerError {
            return .authManager(authError)
        }
        return .message((error as NSError).localizedDescription)
    }

    static func shouldSuppressWebAuthError(_ error: NSError) -> Bool {
        error.domain == ASWebAuthenticationSessionError.errorDomain
            && error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }
}
