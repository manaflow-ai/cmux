public import AppKit
public import WebKit

/// Injected seam that exposes the host browser panel's live WebKit surface and
/// the few app-side side effects the Web Inspector coordinator needs.
///
/// ``BrowserDeveloperToolsCoordinator`` owns all of the developer-tools transition
/// and presentation state, but it cannot retain or import ``BrowserPanel``. The
/// concrete conformer lives in the app target and holds its panel weakly, reading
/// `panel.webView` at call time because the panel reassigns its web view across
/// navigations and profile switches. Inverting the web-view, window-enumeration,
/// hidden-discard, and first-responder-bypass reach behind this protocol keeps the
/// coordinator free of any `BrowserPanel`/`AppDelegate` dependency.
///
/// The conformer must hold its owner weakly to avoid a retain cycle with the
/// coordinator it backs.
@MainActor
public protocol BrowserDeveloperToolsHosting: AnyObject {
    /// The panel's live `WKWebView`, or `nil` when the web view is gone. Read at
    /// call time so the coordinator always drives the current page's inspector.
    var developerToolsWebView: WKWebView? { get }

    /// Short panel id used only for debug logging.
    var developerToolsPanelDebugID: String { get }

    /// All application windows, used to find and dismiss detached inspector
    /// windows. Hosted app-side so the coordinator never reaches `NSApp` directly.
    var developerToolsApplicationWindows: [NSWindow] { get }

    /// Drives the panel's published `preferredDeveloperToolsVisible` mirror. The
    /// panel keeps that `@Published` property as the single observable mirror; the
    /// coordinator is its only writer through this setter.
    func setPreferredDeveloperToolsVisible(_ visible: Bool)

    /// Forwards to the panel's hidden-web-view discard scheduler when developer
    /// tools visibility changes affect whether the page may be discarded.
    func reevaluateHiddenWebViewDiscardScheduling(reason: String)

    /// Notifies the panel that the inspector presentation preference changed so
    /// SwiftUI surfaces reading the panel's local-inline-hosting decision
    /// re-render. The panel forwards this to its own `objectWillChange` on the
    /// main queue, preserving the legacy nudge.
    func developerToolsPresentationPreferenceDidChange()

    /// Runs `body` with the app's browser first-responder bypass engaged, so a
    /// WebKit inspector show during auto-restore does not mutate first responder
    /// while panel attachment is still stabilizing.
    func withBrowserFirstResponderBypass(_ body: () -> Void)
}
