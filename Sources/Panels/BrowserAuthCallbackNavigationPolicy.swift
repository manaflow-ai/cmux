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
///   app. Existing popup delegates run the same disposition and delivery path;
///   new-window creation paths, which cannot safely complete the flow, block
///   callbacks via ``shouldBlockExternalNavigation(_:)``.
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

    /// Consumes a disposition with one lifecycle contract shared by main and
    /// popup navigation delegates. Every consumed WebKit navigation is
    /// cancelled and reported terminally before asynchronous auth work starts.
    /// Delivery completion then receives the validated same-origin return URL,
    /// whether sign-in succeeded or failed, so failures can return to a visible
    /// signed-out retry state instead of leaving navigation bookkeeping open.
    @discardableResult
    func consume(
        disposition: BrowserAuthCallbackNavigationDisposition,
        callbackURL: URL,
        sourcePageURL: URL?,
        cancelNavigation: () -> Void,
        reportTerminalCancellation: () -> Void,
        deliver: @MainActor @escaping (URL) async -> Bool,
        completion: @MainActor @escaping (Bool, URL?) -> Void
    ) -> Bool {
        switch disposition {
        case .passThrough:
            return false
        case .block, .deliverInApp:
            // Every consumed disposition must close WebKit's policy decision
            // before any follow-up work can run. Keeping this outside the
            // delivery-specific branch prevents a new consumed case from
            // accidentally returning with an uncalled handler.
            cancelNavigation()
            reportTerminalCancellation()
        }

        if case .deliverInApp = disposition {
            let returnURL = Self.webReturnURL(fromPageURL: sourcePageURL)
            Task { @MainActor in
                completion(await deliver(callbackURL), returnURL)
            }
        }
        return true
    }

    /// Completes a consumed callback consistently across browser surfaces.
    /// Failed delivery presents a localized error, then returns to the signed-
    /// out source page where the user can restart sign-in. Successful delivery
    /// returns immediately so the refreshed plan state is visible.
    static func finishDelivery(
        delivered: Bool,
        returnURL: URL?,
        in webView: WKWebView,
        prepareReturnRequest: @escaping @MainActor (URLRequest) -> Void,
        presentAlert: BrowserAlertPresenter = browserPresentAlert,
        loadRequest: @escaping @MainActor (URLRequest, WKWebView) -> Void = { request, webView in
            _ = browserLoadRequest(request, in: webView)
        }
    ) {
        let returnToSource: @MainActor () -> Void = { [weak webView] in
            guard let webView, let returnURL else { return }
            let request = URLRequest(url: returnURL)
            prepareReturnRequest(request)
            loadRequest(request, webView)
        }

        guard !delivered else {
            returnToSource()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "account.signIn.error.unknown.title",
            defaultValue: "Couldn\u{2019}t finish sign-in"
        )
        alert.informativeText = String(
            localized: "account.signIn.notCompleted",
            defaultValue: "Sign-in wasn\u{2019}t completed."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        presentAlert(alert, webView, { _ in returnToSource() }, returnToSource)
    }

    /// New-window creation paths cannot express the full disposition because
    /// they create webviews rather than decide policy for an existing one, so
    /// an auth-callback-shaped URL must never reach their generic external-app
    /// prompt. Existing main and popup navigation delegates use
    /// ``disposition(for:url:)`` and ``consume(disposition:callbackURL:sourcePageURL:cancelNavigation:reportTerminalCancellation:deliver:completion:)``.
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
