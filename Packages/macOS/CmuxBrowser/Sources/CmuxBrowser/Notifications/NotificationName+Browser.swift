public import Foundation

/// The `Notification.Name` constants the browser panel posts and observes for
/// web-view first-responder, address-bar focus, omnibar selection, and
/// focus-mode transitions.
///
/// These names are the wire identity of the browser domain's `NotificationCenter`
/// events: the browser panel and web view post them (web-view first-responder
/// hand-off, the address-bar focus/blur/exit lifecycle, the address-bar focus
/// request, the omnibar selection-move delta, the focus-mode state change, and a
/// web-view click), and the app target's window/panel chrome observes them.
/// Every raw string is byte-identical to the literal the app target previously
/// declared inline (`browser*`/`webViewDidReceiveClick`, with the focus-mode name
/// keeping its `cmux.` prefix), so existing observers keyed on these names are
/// unaffected.
extension Notification.Name {
    /// Posted when the browser web view becomes first responder.
    public static let browserDidBecomeFirstResponderWebView = Notification.Name("browserDidBecomeFirstResponderWebView")
    /// Requests that the browser address bar take focus.
    public static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    /// Moves the omnibar selection by the `delta` carried in `userInfo`.
    public static let browserMoveOmnibarSelection = Notification.Name("browserMoveOmnibarSelection")
    /// Posted when focus leaves (exits) the browser address bar.
    public static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
    /// Posted when the browser address bar gains focus.
    public static let browserDidFocusAddressBar = Notification.Name("browserDidFocusAddressBar")
    /// Posted when the browser address bar loses focus.
    public static let browserDidBlurAddressBar = Notification.Name("browserDidBlurAddressBar")
    /// Posted when the browser focus-mode active/armed state changes.
    public static let browserFocusModeStateDidChange = Notification.Name("cmux.browserFocusModeStateDidChange")
    /// Posted when the browser web view receives a click.
    public static let webViewDidReceiveClick = Notification.Name("webViewDidReceiveClick")
}
