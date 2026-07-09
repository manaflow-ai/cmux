/// Where the focus-toggle shortcut should move keyboard focus next, computed from
/// the current effective focus owner.
public enum MainWindowFocusToggleDestination: Equatable {
    /// Focus should move to the terminal / focused main panel.
    case terminal
    /// Focus should move to the right sidebar.
    case rightSidebar
}
