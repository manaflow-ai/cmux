public import Foundation

/// Process-wide tracker for the single most-recent browser middle-click intent.
///
/// Some sites and WebKit paths report middle-click link activations as
/// `WKNavigationAction.buttonNumber=4` instead of `2`. This tracker keeps the
/// most-recently observed middle-click so navigation delegates can recover the
/// intent reliably. It stores one `BrowserMiddleClickIntent` slot, records a new
/// click identity/uptime, and clears the slot on expiry when queried.
///
/// The freshness window and the age/identity predicate live in
/// ``BrowserMiddleClickIntent``; this type owns only the mutable single-slot
/// storage and the evaluate-then-clear lifecycle.
///
/// `@MainActor` because every caller (the web view's `otherMouse` event handlers
/// that record, and the navigation delegates that query) runs on the main actor;
/// co-locating the state with its callers keeps every access a plain call. The
/// app holds one instance per process and forwards `WKWebView` identities and
/// `ProcessInfo.systemUptime` captures into it.
///
/// Faithfully lifted from `CmuxWebView`'s private process-wide
/// `static var lastMiddleClickIntent` slot and its `recordMiddleClickIntent` /
/// `hasRecentMiddleClickIntent` statics.
@MainActor
public final class BrowserMiddleClickIntentTracker {
    private var lastIntent: BrowserMiddleClickIntent?

    /// Creates an empty tracker with no recorded intent.
    public init() {}

    /// Records a middle-click for a web view identity at a captured uptime,
    /// replacing any previously stored intent.
    public func record(webViewID: ObjectIdentifier, uptime: TimeInterval) {
        lastIntent = BrowserMiddleClickIntent(webViewID: webViewID, uptime: uptime)
    }

    /// Reports whether a recent middle-click intent exists for the candidate web
    /// view identity as of `currentUptime`, clearing the stored intent when it has
    /// expired. Reproduces the legacy `hasRecentMiddleClickIntent` flow: no stored
    /// intent is `false`, an expired intent nils the slot and returns `false`, and
    /// a fresh intent returns whether it matches the candidate identity.
    public func hasRecentIntent(
        forWebViewID webViewID: ObjectIdentifier,
        asOf currentUptime: TimeInterval
    ) -> Bool {
        guard let intent = lastIntent else { return false }

        switch intent.evaluate(forWebViewID: webViewID, asOf: currentUptime) {
        case .expired:
            lastIntent = nil
            return false
        case .fresh(let matches):
            return matches
        }
    }
}
