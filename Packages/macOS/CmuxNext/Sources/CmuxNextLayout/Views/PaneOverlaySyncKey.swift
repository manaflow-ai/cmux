import CoreGraphics

/// What a pane's ring and dim were placed from (`LayoutRootView.syncOverlay`): an equal key places
/// them where they are, so the sync skips that pane (no conversion, no window-frame notice).
struct PaneOverlaySyncKey: Equatable {
    var hostFrame: CGRect
    var screenFrame: CGRect
    var screenBounds: CGRect
    /// The root's bounds in window coordinates (nil out of a window): an ancestor that moved the
    /// root moves every pane in the window.
    var rootInWindow: CGRect?
    /// What hides the ring (docks, panes in front), in the screen's coordinates.
    var covers: [CGRect]
    var alpha: CGFloat
    var hidden: Bool
}
