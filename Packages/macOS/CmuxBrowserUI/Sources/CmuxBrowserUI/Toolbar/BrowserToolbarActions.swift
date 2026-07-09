/// Main-actor action closures the browser toolbar/accessory buttons invoke.
///
/// Each closure runs the app-side mutation (panel navigation, screenshot
/// capture, focus-mode toggle, React Grab injection, developer-tools, profile/
/// theme/import popover toggles). Keeping the side effects behind closures lets
/// the toolbar views live in this package while every panel mutation, `#if
/// DEBUG` log, and `@State` popover toggle stays on the app-side forwarder.
public struct BrowserToolbarActions {
    /// Navigate back in history.
    public var onBack: @MainActor () -> Void
    /// Navigate forward in history.
    public var onForward: @MainActor () -> Void
    /// Primary reload/stop button: stop while loading, otherwise reload (with the
    /// command-click duplicate and terminated-content recovery handled app-side).
    public var onReloadOrStop: @MainActor () -> Void
    /// Plain reload from the reload button's context menu.
    public var onReload: @MainActor () -> Void
    /// Hard refresh (cache-bypassing reload) from the context menu.
    public var onHardRefresh: @MainActor () -> Void
    /// Capture the page to the clipboard.
    public var onScreenshot: @MainActor () -> Void
    /// Toggle browser focus mode.
    public var onFocusMode: @MainActor () -> Void
    /// Toggle/inject React Grab from the toolbar button.
    public var onReactGrab: @MainActor () -> Void
    /// Toggle/inject React Grab from the compact overflow menu (distinct log
    /// reason from the toolbar button).
    public var onReactGrabFromOverflow: @MainActor () -> Void
    /// Open the developer tools.
    public var onDevTools: @MainActor () -> Void
    /// Toggle the browser-profile popover.
    public var onProfileToggle: @MainActor () -> Void
    /// Toggle the browser-theme popover.
    public var onThemeToggle: @MainActor () -> Void
    /// Toggle the browser-data import popover.
    public var onImportToggle: @MainActor () -> Void

    /// Creates the toolbar action bundle.
    public init(
        onBack: @escaping @MainActor () -> Void,
        onForward: @escaping @MainActor () -> Void,
        onReloadOrStop: @escaping @MainActor () -> Void,
        onReload: @escaping @MainActor () -> Void,
        onHardRefresh: @escaping @MainActor () -> Void,
        onScreenshot: @escaping @MainActor () -> Void,
        onFocusMode: @escaping @MainActor () -> Void,
        onReactGrab: @escaping @MainActor () -> Void,
        onReactGrabFromOverflow: @escaping @MainActor () -> Void,
        onDevTools: @escaping @MainActor () -> Void,
        onProfileToggle: @escaping @MainActor () -> Void,
        onThemeToggle: @escaping @MainActor () -> Void,
        onImportToggle: @escaping @MainActor () -> Void
    ) {
        self.onBack = onBack
        self.onForward = onForward
        self.onReloadOrStop = onReloadOrStop
        self.onReload = onReload
        self.onHardRefresh = onHardRefresh
        self.onScreenshot = onScreenshot
        self.onFocusMode = onFocusMode
        self.onReactGrab = onReactGrab
        self.onReactGrabFromOverflow = onReactGrabFromOverflow
        self.onDevTools = onDevTools
        self.onProfileToggle = onProfileToggle
        self.onThemeToggle = onThemeToggle
        self.onImportToggle = onImportToggle
    }
}
