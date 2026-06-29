import CmuxAuthRuntime
import CmuxMobileSupport
import Foundation

extension CMUXMobileRootView {
    @MainActor
    func handleOpenURL(_ url: URL) {
        let rawURL = url.absoluteString
        if authCallbackRouter?.isAuthCallbackURL(url) == true {
            if authCallbackErrorCode(from: url) == "mobile_web_sign_in_requires_code" {
                authCallbackError = L10n.string(
                    "auth.error.mobileWebSignInRequiresCode",
                    defaultValue: "For security, enter the code from this email in cmux."
                )
                shouldShowAuthCodeEntry = authManager.hasPendingMagicLinkCode
                return
            }
            authCallbackError = SignInErrorPresentation()
                .message(for: AuthError.invalidCallback)
            return
        }
        if isRawAttachURL(rawURL) {
            connectAttachURL(rawURL)
            return
        }
        guard isAuthenticated else {
            pendingAttachURL = rawURL
            return
        }
        Task {
            await store.connectPairingURL(rawURL)
        }
    }

    private func authCallbackErrorCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_error" })?
            .value
    }
}
