internal import Foundation

/// The outcome of the v2 `browser.focus_webview`, preserving each legacy error
/// shape (distinct from the v1 ``ControlBrowserPanelFocusWebViewResolution``,
/// which uses different codes/messages).
public enum ControlBrowserFocusWebViewResolution: Sendable, Equatable {
    /// The surface did not resolve to a browser of the workspace
    /// (`not_found` / "Surface not found or not a browser",
    /// data `{"surface_id": …}`).
    case notFound
    /// The web view is not attached to a window
    /// (`invalid_state` / "WebView is not in a window").
    case webViewNotInWindow
    /// The web view (or an ancestor) is hidden
    /// (`invalid_state` / "WebView is hidden").
    case webViewHidden
    /// First responder did not land inside the web view
    /// (`internal_error` / "Focus did not move into web view").
    case focusDidNotMove
    /// Focus moved into the web view (`{"focused": true}`).
    case focused
}
