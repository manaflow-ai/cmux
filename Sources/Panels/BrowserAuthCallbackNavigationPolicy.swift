import AppKit
import CmuxAuthRuntime
import Foundation
import WebKit

/// Decides what to do with browser navigations that target cmux auth-callback
/// scheme URLs (`cmux://auth-callback`, `cmux-dev-<tag>://auth-callback`, ...)
/// delivered by the hosted after-sign-in page. WKWebView cannot open native
/// schemes itself, so the navigation delegate consumes the URL and hands it to
/// the app's own URL entrypoint (the stateless-callback fallback in
/// HostBrowserSignInFlow accepts it, without a state check).
///
/// Because the stateless path accepts token-bearing callbacks, the automatic
/// handoff is narrow and fail-closed:
/// - Only a user-activated main-frame link participates. Anything else keeps
///   the browser's regular navigation handling, matching every other custom
///   scheme (and preserving the confirmation prompt those paths show).
/// - The link must come FROM the app's own web origin (the page
///   `/handler/after-sign-in` is served from) and target THIS build's own
///   registered callback scheme, never a sibling build's `cmux-nightly` or
///   `cmux-dev-*` scheme, which another app could have registered.
/// - A user-activated auth-callback link that fails those checks is blocked
///   outright (`.block`), not passed to the generic external-app prompt, so an
///   untrusted page cannot hand attacker-chosen tokens to the app even with a
///   confirming click, and the trusted page cannot route this session's tokens
///   to a different build's handler.
/// - An accepted callback is delivered in-process through the app delegate's
///   `application(_:open:)`, never through `NSWorkspace`/LaunchServices, so
///   the token-bearing URL cannot be routed to whatever app currently claims
///   the scheme.
@MainActor
struct BrowserAuthCallbackNavigationPolicy {
    enum Disposition {
        /// The app's own trusted callback: consume it and deliver in-process.
        case deliverInApp
        /// Auth-callback-shaped URL that failed the trust checks: cancel the
        /// navigation without delivering or prompting.
        case block
        /// Not a user-activated auth callback; regular handling applies.
        case passThrough
    }

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

    func disposition(for navigationAction: WKNavigationAction, url: URL) -> Disposition {
        guard Self.isAuthCallbackShapedURL(url) else { return .passThrough }
        guard navigationAction.targetFrame?.isMainFrame != false,
              navigationAction.navigationType == .linkActivated else {
            return .passThrough
        }
        guard url.scheme?.lowercased() == ownCallbackScheme,
              let trustedSourceOrigin,
              trustedSourceOrigin.matches(navigationAction.sourceFrame.securityOrigin),
              router.isAuthCallbackURL(url) else {
            return .block
        }
        return .deliverInApp
    }

    /// Delivers an accepted callback to the app's canonical URL entrypoint
    /// in-process, exactly as LaunchServices would, without the token-bearing
    /// URL ever leaving this process.
    func deliverAuthCallbackInApp(_ url: URL) -> Bool {
        guard let delegate = NSApp.delegate else { return false }
        guard delegate.application?(NSApp, open: [url]) != nil else { return false }
        return true
    }

    /// Any cmux-family scheme pointing at the auth-callback target, including
    /// schemes this build does not accept (those must be blocked, not opened).
    private static func isAuthCallbackShapedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "cmux" || scheme.hasPrefix("cmux-") else {
            return false
        }
        return AuthCallbackRouter(extraAllowedScheme: scheme).isAuthCallbackURL(url)
    }
}

extension BrowserNavigationDelegate {
    /// Handles auth-callback-shaped navigation actions. Returns `true` when
    /// the navigation was consumed (delivered in-app or blocked); the caller
    /// must stop policy evaluation in that case.
    func handleAuthCallbackNavigationAction(
        _ navigationAction: WKNavigationAction,
        webView: WKWebView,
        decisionHandler: (WKNavigationActionPolicy) -> Void
    ) -> Bool {
        guard let url = navigationAction.request.url else { return false }
        switch authCallbackNavigationPolicy.disposition(for: navigationAction, url: url) {
        case .passThrough:
            return false
        case .deliverInApp:
            clearAttemptedRequest(discardPendingBypasses: true)
            let reportTerminalCancellation = terminalPolicyCancellationReporter?(navigationAction, webView) ?? {}
            let delivered = authCallbackNavigationPolicy.deliverAuthCallbackInApp(url)
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=deliverNativeAuthCallbackInApp " +
                "delivered=\(delivered ? 1 : 0) scheme=\(url.scheme ?? "nil")"
            )
#endif
            if delivered { reportTerminalCancellation() }
            // Cancel even when delivery fails: WKWebView cannot render a
            // native scheme URL, so allowing it only produces an error page.
            decisionHandler(.cancel)
            return true
        case .block:
            clearAttemptedRequest(discardPendingBypasses: true)
#if DEBUG
            cmuxDebugLog(
                "browser.nav.decidePolicy.action kind=blockUntrustedAuthCallback " +
                "scheme=\(url.scheme ?? "nil")"
            )
#endif
            decisionHandler(.cancel)
            return true
        }
    }
}
