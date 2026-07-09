#if os(iOS)
import CmuxMobileSupport

enum DeleteAccountFailureKind {
    case generic
    case connection
    case stackDeleteIncomplete
    case serverCleanupIncomplete
    case timedOut
    case unknown

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
        case .stackDeleteIncomplete:
            return L10n.string(
                "mobile.settings.deleteAccountPartialFailureMessage",
                defaultValue: "Your cmux data was deleted, but account sign-in cleanup did not finish. Try Delete Account again to complete deletion."
            )
        case .serverCleanupIncomplete:
            return L10n.string(
                "mobile.settings.deleteAccountServerCleanupIncompleteMessage",
                defaultValue: "Your account sign-in was deleted, but some cmux cleanup did not finish. You have been signed out. Contact support if cmux data is still visible."
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
