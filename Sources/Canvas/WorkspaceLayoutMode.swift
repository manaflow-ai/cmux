import Foundation

/// How a workspace lays out its panels.
enum WorkspaceLayoutMode: String, Codable, Sendable {
    /// The default bonsplit split-tree layout.
    case splits
    /// The bonsplit split-tree layout wrapped in a zoomable viewport.
    case zoomableSplits
    /// The freeform 2D canvas layout.
    case canvas

    /// Whether terminal panes are mounted directly in the pane hierarchy rather
    /// than through the window-level terminal portal.
    var usesDirectTerminalHosting: Bool {
        switch self {
        case .splits:
            false
        case .zoomableSplits, .canvas:
            true
        }
    }
}
