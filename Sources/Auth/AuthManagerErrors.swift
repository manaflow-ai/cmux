import Foundation

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
        case .message(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return Self.genericLocalizedMessage
            }
            return "\(Self.genericLocalizedMessage) \(trimmed)"
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
    static func signInError(from error: Error) -> AuthSignInError {
        if let authError = error as? AuthManagerError {
            return .authManager(authError)
        }
        return .message((error as NSError).localizedDescription)
    }
}
