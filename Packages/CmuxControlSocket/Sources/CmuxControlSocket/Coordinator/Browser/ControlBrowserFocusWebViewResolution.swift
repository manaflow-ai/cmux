/// The outcome of `browser.focus_webview`, preserving the legacy body's four
/// distinct failures.
public enum ControlBrowserFocusWebViewResolution: Sendable, Equatable {
    /// The workspace or browser panel did not resolve (legacy `not_found` /
    /// "Surface not found or not a browser").
    case notFoundOrNotBrowser
    /// The web view has no window (legacy `invalid_state` /
    /// "WebView is not in a window").
    case webViewNotInWindow
    /// The web view is hidden (legacy `invalid_state` / "WebView is hidden").
    case webViewHidden
    /// First responder did not land inside the web view (legacy
    /// `internal_error` / "Focus did not move into web view").
    case focusDidNotMove
    /// Focus moved into the web view (legacy `.ok({"focused": true})`).
    case focused
}
