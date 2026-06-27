public import Foundation

/// The browser panel / web view state signals the app shell observes to
/// re-evaluate keyboard focus and chrome, broadcast over `NotificationCenter`.
///
/// Each case owns the exact notification name string the app target previously
/// declared inline on `extension Notification.Name`. The post sites
/// (`BrowserPanel`, `CmuxWebView`) and the observe sites (`cmuxApp`,
/// `ContentView`, `BrowserPanelView`) stay app-side; they reach the name through
/// the `Notification.Name` accessors the god still vends, which now forward to
/// `notificationName` here so each wire string lives in one place.
///
/// The wire shape is unchanged. The names are
/// `"cmux.browserFocusModeStateDidChange"` (posted with the browser panel id as
/// `object`) and `"webViewDidReceiveClick"` (posted with the `WKWebView` as
/// `object`).
public enum BrowserPanelSignal: Sendable {
    /// The browser focus-mode (distraction-free) state changed.
    case focusModeStateDidChange
    /// The embedded browser web view received a click.
    case webViewDidReceiveClick

    /// The `NotificationCenter` name for this signal.
    public var notificationName: Notification.Name {
        switch self {
        case .focusModeStateDidChange:
            return Notification.Name("cmux.browserFocusModeStateDidChange")
        case .webViewDidReceiveClick:
            return Notification.Name("webViewDidReceiveClick")
        }
    }
}
