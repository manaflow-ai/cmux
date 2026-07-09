/// Routes the focused-browser and focused-markdown command surface (zoom,
/// browser focus mode, developer tools, and the omnibar toggle) to whichever
/// panel is currently focused.
///
/// TabManager owns the per-window focus state (`selectedWorkspace`, the focused
/// panel id), so it cannot move down into a package. This controller takes that
/// resolution as two injected `@MainActor` closures and forwards each command
/// through the ``FocusedBrowserActing`` / ``FocusedMarkdownZooming`` seams the
/// app-target panels conform to. The bodies are byte-faithful lifts of the
/// former `TabManager.zoomInFocusedBrowser()` and siblings: each resolves the
/// focused panel and forwards, returning `false` when no panel is focused.
///
/// `@MainActor` because every command mutates WebKit/AppKit state on the main
/// thread, matching the callers (keyboard shortcuts, command palette, View
/// menu, the command socket) — state lives where its callers live.
@MainActor
public final class FocusedBrowserController {
    private let resolveFocusedBrowser: @MainActor () -> (any FocusedBrowserActing)?
    private let resolveFocusedMarkdown: @MainActor () -> (any FocusedMarkdownZooming)?

    /// Creates a controller.
    /// - Parameters:
    ///   - resolveFocusedBrowser: returns the focused browser panel, if any.
    ///   - resolveFocusedMarkdown: returns the focused markdown preview panel, if any.
    public init(
        resolveFocusedBrowser: @escaping @MainActor () -> (any FocusedBrowserActing)?,
        resolveFocusedMarkdown: @escaping @MainActor () -> (any FocusedMarkdownZooming)?
    ) {
        self.resolveFocusedBrowser = resolveFocusedBrowser
        self.resolveFocusedMarkdown = resolveFocusedMarkdown
    }

    // MARK: - Browser zoom

    /// Increases the focused browser's page zoom. Returns `false` if no browser is focused.
    @discardableResult
    public func zoomInFocusedBrowser() -> Bool {
        resolveFocusedBrowser()?.zoomIn() ?? false
    }

    /// Decreases the focused browser's page zoom. Returns `false` if no browser is focused.
    @discardableResult
    public func zoomOutFocusedBrowser() -> Bool {
        resolveFocusedBrowser()?.zoomOut() ?? false
    }

    /// Resets the focused browser's page zoom. Returns `false` if no browser is focused.
    @discardableResult
    public func resetZoomFocusedBrowser() -> Bool {
        resolveFocusedBrowser()?.resetZoom() ?? false
    }

    // MARK: - Browser focus mode

    /// Whether the focused browser can toggle focus mode right now.
    public var canToggleBrowserFocusModeForFocusedBrowser: Bool {
        resolveFocusedBrowser()?.canToggleBrowserFocusMode == true
    }

    /// Toggles the focused browser's focus mode. Returns `false` if no browser is focused.
    @discardableResult
    public func toggleBrowserFocusModeForFocusedBrowser(reason: String) -> Bool {
        guard let browserPanel = resolveFocusedBrowser() else { return false }
        return browserPanel.toggleBrowserFocusMode(reason: reason, focusWebView: true)
    }

    /// Sets the focused browser's focus-mode state. Returns `false` if no browser is focused.
    @discardableResult
    public func setFocusedBrowserFocusModeActive(_ active: Bool, reason: String) -> Bool {
        guard let browserPanel = resolveFocusedBrowser() else { return false }
        return browserPanel.setBrowserFocusModeActive(active, reason: reason, focusWebView: active)
    }

    // MARK: - Markdown zoom

    /// Increases the focused markdown preview's zoom. Returns `false` if none is focused.
    @discardableResult
    public func zoomInFocusedMarkdown() -> Bool {
        resolveFocusedMarkdown()?.zoomIn() ?? false
    }

    /// Decreases the focused markdown preview's zoom. Returns `false` if none is focused.
    @discardableResult
    public func zoomOutFocusedMarkdown() -> Bool {
        resolveFocusedMarkdown()?.zoomOut() ?? false
    }

    /// Resets the focused markdown preview's zoom. Returns `false` if none is focused.
    @discardableResult
    public func resetZoomFocusedMarkdown() -> Bool {
        resolveFocusedMarkdown()?.resetZoom() ?? false
    }

    // MARK: - Developer tools

    /// Toggles the focused browser's developer tools. Returns `false` if no browser is focused.
    @discardableResult
    public func toggleDeveloperToolsFocusedBrowser() -> Bool {
        resolveFocusedBrowser()?.toggleDeveloperTools() ?? false
    }

    /// Shows the focused browser's JavaScript console. Returns `false` if no browser is focused.
    @discardableResult
    public func showJavaScriptConsoleFocusedBrowser() -> Bool {
        resolveFocusedBrowser()?.showDeveloperToolsConsole() ?? false
    }

    // MARK: - Omnibar

    /// Toggles the focused browser's omnibar. Returns `false` if no browser is focused.
    @discardableResult
    public func toggleOmnibarFocusedBrowser() -> Bool {
        guard let panel = resolveFocusedBrowser() else { return false }
        panel.toggleOmnibarVisibility()
        return true
    }
}
