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
/// - Only a user-activated main-frame link whose source frame is the app's
///   own web origin (the page `/handler/after-sign-in` is served from), and
///   which targets THIS build's own registered callback scheme, is delivered.
///   Never a sibling build's `cmux-nightly` or `cmux-dev-*` scheme, which
///   another app could have registered.
/// - EVERY other auth-callback-shaped navigation is blocked outright
///   (`.block`), never passed to the generic external-app prompt: JS
///   redirects, subframes, foreign source origins, and sibling schemes. The
///   only legitimate producer of these URLs is the app's own after-sign-in
///   page, and that flow is always a user-activated main-frame link, so
///   anything else offering one is untrusted by construction and one
///   confirming click on a prompt must not hand attacker-chosen tokens to the
///   app. Popup/new-window paths apply the same rule via
///   ``shouldBlockExternalNavigation(_:)``.
/// - An accepted callback is delivered in-process through the app delegate's
///   `application(_:open:)`, never through `NSWorkspace`/LaunchServices, so
///   the token-bearing URL cannot be routed to whatever app currently claims
///   the scheme.
/// - After delivery, the embedded flow returns the webview to the page the
///   sign-in started from, carried in the after-sign-in page's
///   `web_return_to` query item (same-origin relative path only).
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
              navigationAction.navigationType == .linkActivated,
              url.scheme?.lowercased() == ownCallbackScheme,
              let trustedSourceOrigin,
              trustedSourceOrigin.matches(navigationAction.sourceFrame.securityOrigin),
              router.isAuthCallbackURL(url) else {
            return .block
        }
        return .deliverInApp
    }

    /// Popup/new-window navigation paths cannot express the full disposition
    /// (they create webviews rather than decide policies), so they apply the
    /// blanket rule: an auth-callback-shaped URL must never reach the generic
    /// external-app prompt. The legitimate flow is always a main-frame link
    /// handled by ``disposition(for:url:)``.
    static func shouldBlockExternalNavigation(_ url: URL) -> Bool {
        isAuthCallbackShapedURL(url)
    }

    /// After an accepted in-webview delivery, the embedded flow returns the
    /// webview to where the sign-in started. The after-sign-in page carries
    /// that location in its `web_return_to` query item; only a same-origin
    /// relative path is honored.
    static func webReturnURL(fromPageURL pageURL: URL?) -> URL? {
        guard let pageURL,
              let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "web_return_to" })?.value,
              value.hasPrefix("/"),
              !value.hasPrefix("//") else {
            return nil
        }
        return URL(string: value, relativeTo: pageURL)?.absoluteURL
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
            let sourcePageURL = webView.url
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
            if delivered,
               let returnURL = BrowserAuthCallbackNavigationPolicy.webReturnURL(fromPageURL: sourcePageURL) {
                recordAttemptedRequest(URLRequest(url: returnURL))
                _ = browserLoadRequest(URLRequest(url: returnURL), in: webView)
            }
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
