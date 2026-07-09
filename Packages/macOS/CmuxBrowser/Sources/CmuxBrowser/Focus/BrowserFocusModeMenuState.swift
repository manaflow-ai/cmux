/// The derived state the View menu's browser-focus-mode item renders from the
/// currently focused browser panel.
///
/// The menu shows one of two titles (enter vs exit focus mode) and is enabled
/// only while the focused panel can toggle focus mode. `TabManager` owns the
/// focused-panel resolution and cannot move into this package, so the app
/// derives the focused panel's two booleans (`isBrowserFocusModeActive`,
/// `canToggleBrowserFocusMode`) and constructs this value; this type owns the
/// title-variant decision (active shows "exit", inactive shows "enter").
///
/// The localized title strings stay app-side: `String(localized:)` resolves
/// against the bundle of the module that calls it, so resolving here would bind
/// to the package bundle (which lacks the keys) and silently drop non-English
/// translations. The menu therefore maps ``title`` to its localized string at
/// the call site in the app target.
public struct BrowserFocusModeMenuState: Equatable, Sendable {
    /// Which title the menu item shows.
    public enum Title: Equatable, Sendable {
        /// Focus mode is inactive; the item enters focus mode.
        case enterBrowserFocusMode
        /// Focus mode is active; the item exits focus mode.
        case exitBrowserFocusMode
    }

    /// The title variant to display.
    public let title: Title

    /// Whether the menu item is enabled (the focused panel can toggle focus mode).
    public let canToggle: Bool

    /// Derives the menu state from the focused browser panel's two booleans.
    /// - Parameters:
    ///   - isFocusModeActive: whether the focused panel currently has focus mode active.
    ///   - canToggle: whether the focused panel can toggle focus mode right now.
    public init(isFocusModeActive: Bool, canToggle: Bool) {
        self.title = isFocusModeActive ? .exitBrowserFocusMode : .enterBrowserFocusMode
        self.canToggle = canToggle
    }
}
