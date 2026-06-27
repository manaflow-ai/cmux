public import Foundation

/// A recorded middle-click on a browser web view, used to recover navigation
/// intent when WebKit reports the activation as `WKNavigationAction.buttonNumber=4`
/// instead of `2`.
///
/// Carries the identity of the web view that was middle-clicked
/// (`ObjectIdentifier`) and the `ProcessInfo.systemUptime` at which the click
/// happened. The freshness window and the age/identity predicate live here so a
/// recorded intent only counts when it is both recent and for the same web view.
///
/// The process-wide storage (the single most-recent intent) plus the record and
/// has-recent entry points stay app-side on `CmuxWebView` (the `static var
/// lastMiddleClickIntent` and its `record`/`hasRecent` statics): they mutate a
/// `WKWebView`-typed slot and clear it on expiry, which is app-target state. This
/// type owns only the immutable freshness value and its predicate.
///
/// Faithfully lifted from the app target's private `CmuxWebView.MiddleClickIntent`
/// struct, the `middleClickIntentMaxAge` constant (`0.8` seconds), and the
/// age/identity check inside `hasRecentMiddleClickIntent(for:)`.
public struct BrowserMiddleClickIntent: Sendable, Equatable {
    /// The maximum age, in seconds, for which a recorded middle-click intent is
    /// still considered fresh. Matches the legacy `middleClickIntentMaxAge`.
    public static let maxAge: TimeInterval = 0.8

    /// Identity of the web view that was middle-clicked.
    public let webViewID: ObjectIdentifier

    /// `ProcessInfo.processInfo.systemUptime` captured when the click happened.
    public let uptime: TimeInterval

    /// Creates an intent for a web view identity at a captured uptime.
    public init(webViewID: ObjectIdentifier, uptime: TimeInterval) {
        self.webViewID = webViewID
        self.uptime = uptime
    }

    /// The outcome of evaluating a recorded intent against the current time and a
    /// candidate web view identity.
    public enum Freshness: Sendable, Equatable {
        /// The intent is older than `maxAge`; the caller should discard its
        /// stored intent (the legacy path nils out `lastMiddleClickIntent`).
        case expired
        /// The intent is recent; `matches` is `true` when it is for the candidate
        /// web view identity.
        case fresh(matches: Bool)
    }

    /// Evaluates this intent against the current uptime and a candidate web view
    /// identity, reproducing the legacy `hasRecentMiddleClickIntent` predicate:
    /// an age greater than `maxAge` is `.expired`, otherwise `.fresh` carrying
    /// whether the stored identity equals `webViewID`.
    public func evaluate(
        forWebViewID webViewID: ObjectIdentifier,
        asOf currentUptime: TimeInterval
    ) -> Freshness {
        let age = currentUptime - uptime
        if age > Self.maxAge {
            return .expired
        }
        return .fresh(matches: self.webViewID == webViewID)
    }
}
