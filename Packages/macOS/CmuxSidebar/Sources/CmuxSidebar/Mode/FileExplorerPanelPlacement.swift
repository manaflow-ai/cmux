/// Where a file-explorer panel is hosted in the window.
///
/// A pure, `Sendable` value with no AppKit, localization, or settings coupling:
/// the panel either fills the right sidebar or lives inside a terminal pane.
public enum FileExplorerPanelPlacement: Equatable, Sendable {
    /// The panel fills the right sidebar (the ⌘⌥B-toggled column).
    case rightSidebar
    /// The panel is embedded inside a terminal pane.
    case pane
}
