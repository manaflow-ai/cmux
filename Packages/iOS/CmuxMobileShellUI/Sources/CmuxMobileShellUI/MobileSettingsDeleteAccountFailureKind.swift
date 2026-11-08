#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileSupport

enum DeleteAccountFailureKind: Equatable {
    case generic
    case connection
    case unauthorized
    case stackDeleteIncomplete
    case serverCleanupIncomplete
    case timedOut
    case unknown

    init(error: any Error) {
        if case AccountDeletionRequestError.unauthorized = error {
            self = .unauthorized
        } else if case AuthError.unauthorized = error {
            self = .unauthorized
        } else if case AccountDeletionRequestError.stackDeleteIncomplete = error {
            self = .stackDeleteIncomplete
        } else if case AccountDeletionRequestError.timedOut = error {
            self = .timedOut
        } else if case AccountDeletionRequestError.completionUnknown = error {
            self = .unknown
        } else if case AccountDeletionRequestError.localTransportFailure = error {
            self = .connection
        } else if case AuthError.timedOut = error {
            self = .timedOut
        } else {
            self = .generic
        }
    }

    var signsOutAfterAcknowledgement: Bool {
        self == .serverCleanupIncomplete || self == .unauthorized
    }

    var localizedTitle: String {
        switch self {
        case .serverCleanupIncomplete:
            return L10n.string(
                "mobile.settings.deleteAccountCleanupIncompleteTitle",
                defaultValue: "Account Deleted"
            )
        default:
            return L10n.string(
                "mobile.settings.deleteAccountFailedTitle",
                defaultValue: "Couldn't Delete Account"
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .generic:
            return L10n.string(
                "mobile.settings.deleteAccountFailedMessage",
                defaultValue: "Try again later or contact support."
            )
        case .connection:
            return L10n.string(
                "mobile.settings.deleteAccountConnectionFailedMessage",
                defaultValue: "Could not reach the server. Check your internet connection and try again."
            )
        case .unauthorized:
            return L10n.string(
                "mobile.settings.deleteAccountUnauthorizedMessage",
                defaultValue: "Your session is no longer valid. You will be signed out on this device. Sign in again if the account still exists."
            )
        case .stackDeleteIncomplete:
            return L10n.string(
                "mobile.settings.deleteAccountPartialFailureMessage",
                defaultValue: "Your cmux data was deleted, but account sign-in cleanup did not finish. Try Delete Account again to complete deletion."
            )
        case .serverCleanupIncomplete:
            return L10n.string(
                "mobile.settings.deleteAccountServerCleanupIncompleteMessage",
                defaultValue: "Your account sign-in was deleted, but some cmux cleanup did not finish. You will be signed out. Contact support if cmux data is still visible."
            )
        case .timedOut:
            return L10n.string(
                "mobile.settings.deleteAccountTimedOutMessage",
                defaultValue: "Account deletion timed out. Check your connection and try again."
            )
        case .unknown:
            return L10n.string(
                "mobile.settings.deleteAccountUnknownMessage",
                defaultValue: "We couldn't confirm whether account deletion finished. Wait a moment, then try Delete Account again."
            )
        }
    }
}
#endif
