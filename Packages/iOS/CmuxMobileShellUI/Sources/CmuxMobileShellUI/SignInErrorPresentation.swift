import CmuxAuthRuntime
import CmuxMobileSupport
import Foundation
import StackAuth

struct SignInErrorPresentation {
    /// Maps a sign-in error to the `ios_sign_in_failed` `failure_reason` enum
    /// (enums only, never the error text or the user's email).
    func failureReason(for error: Error) -> String {
        if let authError = error as? AuthError {
            switch authError {
            case .timedOut:
                return "timeout"
            case .offline:
                return "offline"
            case .networkError:
                return "network"
            default:
                break
            }
        }
        if let stackError = error as? StackAuthErrorProtocol {
            switch stackError.code.uppercased() {
            case "VERIFICATION_CODE_ERROR", "INVALID_OTP", "INVALID_TOTP_CODE":
                return "invalid_code"
            case "OTP_EXPIRED":
                return "code_expired"
            case "RATE_LIMIT", "RATE_LIMITED":
                return "rate_limit"
            default:
                return "oauth_error"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "network"
        }
        return "other"
    }

    func message(for error: Error) -> String {
        let displayError = AuthError(displaySafe: error) ?? error
        if let stackError = displayError as? StackAuthErrorProtocol {
            switch stackError.code.uppercased() {
            case "SCHEMA_ERROR":
                return L10n.string("auth.error.invalid_email", defaultValue: "Please enter a valid email address.")
            case "USER_EMAIL_ALREADY_EXISTS":
                return L10n.string("auth.error.email_exists", defaultValue: "An account with this email already exists. Try signing in instead.")
            case "VERIFICATION_CODE_ERROR", "INVALID_OTP":
                return L10n.string("auth.error.invalid_code", defaultValue: "Invalid code. Please check and try again.")
            case "OTP_EXPIRED":
                return L10n.string("auth.error.code_expired", defaultValue: "Code expired. Please request a new one.")
            case "RATE_LIMIT", "RATE_LIMITED":
                return L10n.string("auth.error.rate_limit", defaultValue: "Too many attempts. Please wait a moment and try again.")
            case "EMAIL_PASSWORD_MISMATCH":
                return L10n.string("auth.error.wrong_password", defaultValue: "Incorrect email or password.")
            case "USER_NOT_FOUND":
                return L10n.string("auth.error.user_not_found", defaultValue: "No account found with this email.")
            case "PASSKEY_AUTHENTICATION_FAILED", "PASSKEY_WEBAUTHN_ERROR":
                return L10n.string("auth.error.passkey_failed", defaultValue: "Passkey authentication failed. Please try again.")
            case "INVALID_TOTP_CODE":
                return L10n.string("auth.error.invalid_mfa", defaultValue: "Incorrect verification code. Please try again.")
            case "REDIRECT_URL_NOT_WHITELISTED", "INVALID_URL":
                return L10n.string("auth.error.config", defaultValue: "Sign in is temporarily unavailable. Please try again later.")
            case "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN":
                return L10n.string("auth.error.oauth_linked", defaultValue: "This account is already linked to another sign-in method.")
            case
                "INVALID_APPLE_CREDENTIALS",
                "APPLE_SIGNIN_NOT_CONFIGURED",
                "APPLE_SIGNIN_NOT_HANDLED",
                "APPLE_SIGNIN_INVALID_RESPONSE",
                "APPLE_SIGNIN_FAILED",
                "APPLE_SIGNIN_NOT_INTERACTIVE",
                "APPLE_SIGNIN_ERROR":
                return L10n.string("auth.error.apple_config", defaultValue: "Apple Sign In is not available yet. Please use another sign-in method.")
            case "OAUTH_ERROR", "MISSING_CODE", "PARSE_ERROR", "INVALID_RESPONSE":
                return L10n.string("auth.error.browser_sign_in_failed", defaultValue: "Could not complete browser sign-in. Try again or open sign-in in your browser.")
            default:
                break
            }
        }

        if let authError = displayError as? AuthError {
            return authError.localizedDescription
        }

        let nsError = displayError as NSError
        if nsError.domain == NSURLErrorDomain {
            return L10n.string("auth.error.network", defaultValue: "Could not connect to the server. Check your internet connection and try again.")
        }

        #if DEBUG
        var debug = "\(displayError.localizedDescription)\n\(String(reflecting: type(of: displayError)))"
        if let stackError = displayError as? StackAuthErrorProtocol {
            debug += "\ncode: \(stackError.code)\nmessage: \(stackError.message)"
            if let details = stackError.details {
                debug += "\ndetails: \(details)"
            }
        }
        return debug
        #else
        return L10n.string("auth.error.generic", defaultValue: "Something went wrong. Please try again.")
        #endif
    }
}
