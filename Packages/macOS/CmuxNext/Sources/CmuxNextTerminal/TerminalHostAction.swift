/// Window, tab, and split requests from Ghostty keybinds (`new_tab`,
/// `goto_split:left`, ...). Layout lives in cmux-tui, so the App maps these to
/// daemon commands; the terminal module never acts on them.
public nonisolated enum TerminalHostAction: Sendable, Equatable {
    public enum SplitDirection: Sendable, Equatable { case right, down, left, up }
    public enum SplitNavigation: Sendable, Equatable { case previous, next, up, down, left, right }
    public enum TabTarget: Sendable, Equatable { case previous, next, last, index(Int) }
    public enum CloseTabMode: Sendable, Equatable { case this, others, right }

    case newWindow
    case newTab
    case closeTab(CloseTabMode)
    case closeWindow
    case closeAllWindows
    case quit
    case newSplit(SplitDirection)
    case gotoSplit(SplitNavigation)
    case resizeSplit(SplitDirection, amount: Int)
    case equalizeSplits
    case toggleSplitZoom
    case gotoTab(TabTarget)
    case moveTab(Int)
    case toggleFullscreen
    case toggleMaximize
    case toggleCommandPalette
    case toggleInspector
    case promptTitle
    case checkForUpdates
    case undo
    case redo
    /// Open the host's find UI (copy mode's `/`).
    case find
    /// Show or hide every window of the app (`toggle_visibility`).
    case toggleVisibility
    /// Ghostty's tab overview (`toggle_tab_overview`).
    case toggleTabOverview
    /// Ask for a window title (`prompt_window_title`).
    case promptWindowTitle
    /// Set the window title (`set_window_title:<title>`).
    case setWindowTitle(String)
    /// Bring this terminal to the front (`present_terminal`).
    case presentTerminal
    /// Focus the next or previous window (`goto_window:next|previous`).
    case gotoWindow(next: Bool)
    /// Move this terminal's tab to a new window (`move_tab_to_new_window`).
    case moveTabToNewWindow
}
