import CmuxAuthRuntime
import Foundation
import WebKit

/// Decides when a browser navigation targets the app's own auth-callback
/// scheme URLs (`cmux://auth-callback`, `cmux-dev-<tag>://auth-callback`, ...)
/// delivered by the hosted after-sign-in page. WKWebView cannot open native
/// schemes itself, so the navigation delegate hands the URL to the OS, which
/// routes it to this app's URL handler (the stateless-callback fallback in
/// HostBrowserSignInFlow accepts it, without a state check).
///
/// Because the stateless path accepts token-bearing callbacks, this intercept
/// must be narrow: it requires a user-activated main-frame link whose SOURCE
/// frame is the app's own web origin (the page `/handler/after-sign-in` is
/// served from), and the destination scheme must be THIS build's own
/// registered callback scheme (never a sibling build's `cmux-nightly` or
/// `cmux-dev-*` scheme, which another app could have registered). Anything
/// else falls through to the regular external-navigation handling, so an
/// untrusted page cannot hand attacker-chosen tokens to the app and the
/// trusted page cannot route this session's tokens to a different handler.
@MainActor
struct BrowserAuthCallbackNavigationPolicy {
    private let router: AuthCallbackRouter
    private let ownCallbackScheme: String
    // Reuses the browser's normalized origin value (scheme/host/port
    // comparison rules are identical to the WebAuthn caller-origin check).
    private let trustedSourceOrigin: BrowserWebAuthnSecurityOrigin?

    init(
        trustedSourcePageOrigin: URL = AuthEnvironment.appWebOrigin,
        callbackScheme: String = AuthEnvironment.callbackScheme
    ) {
        trustedSourceOrigin = BrowserWebAuthnSecurityOrigin(url: trustedSourcePageOrigin)
        ownCallbackScheme = callbackScheme.lowercased()
        router = AuthCallbackRouter(extraAllowedScheme: callbackScheme)
    }

    func shouldOpenNativeAuthCallbackInApp(_ navigationAction: WKNavigationAction, url: URL) -> Bool {
        guard navigationAction.targetFrame?.isMainFrame != false else { return false }
        guard navigationAction.navigationType == .linkActivated else { return false }
        guard url.scheme?.lowercased() == ownCallbackScheme else { return false }
        guard let trustedSourceOrigin,
              trustedSourceOrigin.matches(navigationAction.sourceFrame.securityOrigin) else {
            return false
        }
        return router.isAuthCallbackURL(url)
    }
}
