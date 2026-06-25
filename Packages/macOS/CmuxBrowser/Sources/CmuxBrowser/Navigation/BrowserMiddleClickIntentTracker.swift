public import Foundation
import ObjectiveC

/// Records and answers "was there a recent middle-click on this web view".
///
/// Some sites and WebKit code paths report middle-click link activations as
/// `WKNavigationAction.buttonNumber == 4` instead of `2`, so the navigation and
/// UI delegates cannot rely on the navigation action alone to recover
/// open-in-new-tab intent. The owning view records a local middle-click here on
/// `otherMouseDown`/`otherMouseUp`, and the delegates ask whether a recent
/// middle-click exists for the navigating web view.
///
/// This replaces the former process-static state on `CmuxWebView`
/// (`lastMiddleClickIntent` + `middleClickIntentMaxAge` +
/// `hasRecentMiddleClickIntent(for:)`/`recordMiddleClickIntent(for:)`). It is a
/// constructor-injected `@MainActor` instance keyed by `ObjectIdentifier`, with
/// the monotonic clock injected (`ProcessInfo.systemUptime` in production) so the
/// expiry policy is unit-testable. Stale entries expire on read.
@MainActor
public final class BrowserMiddleClickIntentTracker {
    /// One recorded middle-click: which web view, and when (monotonic uptime).
    private struct MiddleClickIntent {
        let webViewID: ObjectIdentifier
        let uptime: TimeInterval
    }

    /// How long after a middle-click the intent is still considered "recent".
    private let maxAge: TimeInterval
    /// Monotonic uptime source, injected for testability.
    private let uptime: () -> TimeInterval
    /// The most recent recorded middle-click intent, if any.
    private var lastIntent: MiddleClickIntent?

    /// Creates a tracker.
    ///
    /// - Parameters:
    ///   - maxAge: How long a recorded middle-click stays "recent". Defaults to
    ///     the legacy `0.8` seconds.
    ///   - uptime: Monotonic clock used to timestamp and expire intents. Defaults
    ///     to `ProcessInfo.processInfo.systemUptime`.
    public init(
        maxAge: TimeInterval = 0.8,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maxAge = maxAge
        self.uptime = uptime
    }

    /// Records a middle-click for the given object (the web view), stamped with
    /// the current monotonic uptime.
    public func record(for webView: AnyObject) {
        lastIntent = MiddleClickIntent(
            webViewID: ObjectIdentifier(webView),
            uptime: uptime()
        )
    }

    /// Answers whether a non-expired middle-click was recorded for the given
    /// object (the web view). Expires the stored intent on read when it has aged
    /// past `maxAge`.
    public func hasRecentIntent(for webView: AnyObject) -> Bool {
        guard let intent = lastIntent else { return false }

        let age = uptime() - intent.uptime
        if age > maxAge {
            lastIntent = nil
            return false
        }

        return intent.webViewID == ObjectIdentifier(webView)
    }
}
