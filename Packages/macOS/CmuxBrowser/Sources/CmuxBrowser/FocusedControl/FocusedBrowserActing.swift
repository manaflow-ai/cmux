/// The per-panel browser actions the app target drives against the focused
/// browser panel: page-zoom, browser focus mode, developer tools, and the
/// omnibar toggle.
///
/// This is the inversion seam for the focused-browser command surface. The
/// concrete browser panel lives in the app target (it owns the WebKit
/// `WKWebView` and the AppKit window chrome), so a lower package cannot import
/// it. Instead the panel conforms to this protocol and ``FocusedBrowserController``
/// forwards each command through it, after the app-side composition root
/// resolves which panel is focused.
///
/// `@MainActor` because every action mutates WebKit/AppKit state on the main
/// thread; the protocol exists where its callers live.
@MainActor
public protocol FocusedBrowserActing: AnyObject {
    /// Whether the browser focus-mode toggle command can act right now (it is
    /// either already active, or the panel can currently enter focus mode).
    var canToggleBrowserFocusMode: Bool { get }

    /// Increases the page zoom by one step. Returns whether the zoom changed.
    @discardableResult
    func zoomIn() -> Bool

    /// Decreases the page zoom by one step. Returns whether the zoom changed.
    @discardableResult
    func zoomOut() -> Bool

    /// Resets the page zoom to 100%. Returns whether the zoom changed.
    @discardableResult
    func resetZoom() -> Bool

    /// Toggles browser focus mode, focusing the web view on activation.
    /// - Parameters:
    ///   - reason: a short diagnostic tag describing the trigger.
    ///   - focusWebView: whether to move focus into the web view when entering.
    /// - Returns: whether the toggle was applied.
    @discardableResult
    func toggleBrowserFocusMode(reason: String, focusWebView: Bool) -> Bool

    /// Sets browser focus mode to an explicit active state.
    /// - Parameters:
    ///   - active: the desired focus-mode state.
    ///   - reason: a short diagnostic tag describing the trigger.
    ///   - focusWebView: whether to move focus into the web view.
    /// - Returns: whether the change was applied.
    @discardableResult
    func setBrowserFocusModeActive(_ active: Bool, reason: String, focusWebView: Bool) -> Bool

    /// Toggles the attached developer tools. Returns whether the toggle was applied.
    @discardableResult
    func toggleDeveloperTools() -> Bool

    /// Shows the developer tools and selects the JavaScript console.
    /// Returns whether the console was shown.
    @discardableResult
    func showDeveloperToolsConsole() -> Bool

    /// Toggles the omnibar (address-bar overlay) visibility.
    /// Returns the resulting visibility.
    @discardableResult
    func toggleOmnibarVisibility() -> Bool
}
