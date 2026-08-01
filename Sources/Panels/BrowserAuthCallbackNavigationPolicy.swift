import AppKit
import CmuxAuthRuntime
import Foundation
import WebKit

/// Decides what to do with browser navigations that target cmux auth-callback
/// scheme URLs (`cmux://auth-callback`, `cmux-dev-<tag>://auth-callback`, ...)
/// delivered by the hosted after-sign-in page. WKWebView cannot open native
/// schemes itself, so the navigation delegate consumes the URL and hands it to
/// the app's shared native callback entrypoint (the stateless-callback fallback in
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
///   auth handler, never through `NSWorkspace`/LaunchServices, so
///   the token-bearing URL cannot be routed to whatever app currently claims
///   the scheme.
/// - After delivery, the embedded flow returns the webview to the page the
///   sign-in started from, carried in the after-sign-in page's
///   `web_return_to` query item (same-origin relative path only).
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

    func disposition(
        for navigationAction: WKNavigationAction,
        url: URL
    ) -> BrowserAuthCallbackNavigationDisposition {
        disposition(
            for: url,
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame == true,
            isLinkActivated: navigationAction.navigationType == .linkActivated,
            sourceOriginMatches: trustedSourceOrigin?.matches(
                navigationAction.sourceFrame.securityOrigin
            ) == true
        )
    }

    /// Pure policy seam used by the WebKit adapter and unit tests. Keeping
    /// WebKit object access outside the decision makes every trust check
    /// independently testable without fabricating WKNavigationAction values.
    func disposition(
        for url: URL,
        targetFrameIsMainFrame: Bool,
        isLinkActivated: Bool,
        sourceOriginMatches: Bool
    ) -> BrowserAuthCallbackNavigationDisposition {
        guard Self.isAuthCallbackShapedURL(url) else { return .passThrough }
        guard targetFrameIsMainFrame,
              isLinkActivated,
              sourceOriginMatches,
              url.scheme?.lowercased() == ownCallbackScheme,
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

    /// Delivers an accepted callback through the app's shared auth entrypoint
    /// without sending the token-bearing URL through LaunchServices. Success
    /// means the account flow completed, not merely that dispatch started.
    func deliverAuthCallbackInApp(_ url: URL) async -> Bool {
        guard let delegate = NSApp.delegate as? AppDelegate else { return false }
        return await delegate.handleAuthCallbackURLInProcess(url)
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
