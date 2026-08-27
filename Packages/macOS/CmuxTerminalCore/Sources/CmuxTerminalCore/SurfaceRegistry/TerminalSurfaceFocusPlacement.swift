/// Where a terminal surface participates in focus routing.
///
/// Most surfaces live in a workspace pane; right-sidebar dock terminals are
/// excluded from workspace focus cycling and main-window focus restoration.
public enum TerminalSurfaceFocusPlacement: Equatable, Sendable {
    /// The surface is hosted in a workspace pane.
    case workspace

    /// The surface is hosted in the right-sidebar dock.
    case rightSidebarDock
}
