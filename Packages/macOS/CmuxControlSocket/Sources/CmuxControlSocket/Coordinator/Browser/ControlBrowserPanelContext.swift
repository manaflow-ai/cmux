public import Foundation

/// The browser-panel slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella): live app reach for the v1 line-protocol
/// browser commands (`open_browser` / `navigate` / `browser_back` /
/// `browser_forward` / `browser_reload` / `get_url` / `focus_webview` /
/// `is_webview_focused`) plus the browser-availability reads the v1 pane and
/// surface creation commands share. Distinct from ``ControlBrowserContext``,
/// which serves the v2 `browser.*` methods.
///
/// `@MainActor` because its conformer lives on the main actor and the
/// coordinator runs there too.
@MainActor
public protocol ControlBrowserPanelContext: AnyObject {
    /// Whether the active `TabManager` is wired (the legacy
    /// `guard let tabManager` head of every browser v1 body).
    func controlBrowserPanelTabManagerAvailable() -> Bool

    /// Whether the embedded cmux browser is enabled
    /// (`BrowserAvailabilitySettings.isEnabled()`; disabled is its negation).
    func controlBrowserPanelAvailabilityEnabled() -> Bool

    /// Opens a URL in the external default browser (the disabled-browser
    /// fallback), returning whether the open succeeded.
    func controlBrowserPanelOpenURLExternally(_ url: URL) -> Bool

    /// Creates a browser split off the selected workspace's focused panel for
    /// `open_browser` (focus allowance read app-side from the active
    /// socket-command policy). Returns the new panel id, or `nil` on failure.
    func controlBrowserPanelOpen(url: URL?) -> UUID?

    /// Smart-navigates a browser panel (`navigate`); `false` when the panel
    /// does not resolve to a browser of the selected workspace.
    func controlBrowserPanelNavigate(panelID: UUID, urlString: String) -> Bool

    /// Navigates back (`browser_back`); `false` when the panel does not
    /// resolve.
    func controlBrowserPanelGoBack(panelID: UUID) -> Bool

    /// Navigates forward (`browser_forward`); `false` when the panel does not
    /// resolve.
    func controlBrowserPanelGoForward(panelID: UUID) -> Bool

    /// Reloads (`browser_reload`); `false` when the panel does not resolve.
    func controlBrowserPanelReload(panelID: UUID) -> Bool

    /// The current URL absolute string (`get_url`), an empty string when the
    /// panel has no URL, or `nil` when the panel does not resolve.
    func controlBrowserPanelCurrentURLString(panelID: UUID) -> String?

    /// Moves first responder into the web view (`focus_webview`).
    func controlBrowserPanelFocusWebView(panelID: UUID) -> ControlBrowserPanelFocusWebViewResolution

    /// Whether the web view holds focus (`is_webview_focused`).
    func controlBrowserPanelIsWebViewFocused(panelID: UUID) -> ControlBrowserPanelWebViewFocusState
}
