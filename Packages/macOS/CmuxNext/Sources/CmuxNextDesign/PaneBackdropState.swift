public import AppKit

/// A pane's background state (`PaneContentView+Backdrop`): its own pick and marker tint, and the
/// views made for them on first use (none in the common case).
@MainActor
public final class PaneBackdropState {
    public init() {}

    /// The pane's own pick; `inherit` follows its workspace.
    public var pin: BackdropPin = .inherit
    /// The pane's marker tint (its own, else its tab's, workspace's or window's).
    public var tint: PaneTint?
    /// The pane's own glass tint over art; nil follows its workspace.
    public var glass: Double?
    /// The pane's place among its workspace's panes: which of the theme's pane pictures it takes (`appearance.paneArt.*`).
    public var artIndex = 0
    /// The pane's copy of the art and its tint, under everything.
    public var artView: WindowMaterialView?
    /// The plain background over the window's art (the pane's own `none`).
    public var coverView: NSView?
    /// The marker tint over the pane.
    public var tintView: PaneTintView?

    /// Whether anything of the pane's own is set.
    public var hasOwnValues: Bool { pin != .inherit || tint != nil || glass != nil }
    /// Whether a view was made (it must be hidden again when the values go).
    public var hasViews: Bool { artView != nil || coverView != nil || tintView != nil }
}
