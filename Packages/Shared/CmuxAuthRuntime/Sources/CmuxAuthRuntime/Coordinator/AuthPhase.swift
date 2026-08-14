import Foundation

/// The sign-in/session phase a deadline applies to. Used as the stable label
/// in timeout diagnostics so a stuck-at-sign-in report names the exact phase.
enum AuthPhase: String, Sendable, Hashable {
    case sendCode = "send_code"
    case verifyCode = "verify_code"
    case passwordSignIn = "password_sign_in"
    case oauth = "oauth"
    case accessToken = "access_token"
    case forceRefreshAccessToken = "force_refresh_access_token"
    case fetchUser = "fetch_user"
    case validateSession = "validate_session"
    case listTeams = "list_teams"
    case postSignIn = "post_sign_in"
    case accountDeletion = "account_deletion"
}
