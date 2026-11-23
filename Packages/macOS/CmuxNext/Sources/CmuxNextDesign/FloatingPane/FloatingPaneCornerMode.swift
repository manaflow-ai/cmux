public import CmuxNextDesignTokens

/// What a floating pane's corners follow, as a Debug Settings choice (``FloatingPaneTunables/cornerMode``).
public nonisolated enum FloatingPaneCornerMode: String, Sendable, CaseIterable, TunableChoice {
    /// Each corner is concentric with the app window's corner: the window's radius less the corner's distance
    /// from the window's edges, and never below the corner floor.
    case concentric
    /// The pane looks like a small window: each corner has the window's own radius at each place.
    case window
    /// Each corner has the main pane's radius.
    case mainPane

    public var tunableTitle: String {
        switch self {
        case .concentric: "Concentric with the window"
        case .window: "The window's radius"
        case .mainPane: "Main pane's radius"
        }
    }
}
