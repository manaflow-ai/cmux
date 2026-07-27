internal import Foundation

/// The outcome of the v1 line-protocol `focus_webview` command, preserving
/// each legacy error string (distinct from the v2 `browser.focus_webview`
/// resolution).
public enum ControlBrowserPanelFocusWebViewResolution: Sendable, Equatable {
    /// The panel did not resolve to a browser panel of the selected workspace.
    case panelNotFound
    /// The web view is not attached to a window.
    case webViewNotInWindow
    /// The web view (or an ancestor) is hidden.
    case webViewHidden
    /// First responder did not land inside the web view.
    case focusDidNotMove
    /// Focus moved into the web view.
    case focused
}
