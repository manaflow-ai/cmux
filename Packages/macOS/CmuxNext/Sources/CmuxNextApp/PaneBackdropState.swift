import AppKit
import CmuxNextDesign

/// A pane's background state (`PaneContentView+Backdrop`): its own pick and marker tint, and the
/// views made for them on first use (none in the common case).
@MainActor
final class PaneBackdropState {
    /// The pane's own pick; `inherit` follows its workspace.
    var pin: BackdropPin = .inherit
    /// The pane's marker tint (its own, else its tab's, workspace's or window's).
    var tint: PaneTint?
    /// The pane's own glass tint over art; nil follows its workspace.
    var glass: Double?
    /// The pane's copy of the art and its tint, under everything.
    var artView: WindowMaterialView?
    /// The plain background over the window's art (the pane's own `none`).
    var coverView: NSView?
    /// The marker tint over the pane.
    var tintView: PaneTintView?

    /// Whether anything of the pane's own is set.
    var hasOwnValues: Bool { pin != .inherit || tint != nil || glass != nil }
    /// Whether a view was made (it must be hidden again when the values go).
    var hasViews: Bool { artView != nil || coverView != nil || tintView != nil }
}
