import AppKit
import CmuxNextDesign

/// A pane's background state (`PaneContentView+Backdrop`): its own pick and marker tint, and the
/// views made for them on first use (none in the common case).
@MainActor
final class PaneBackdropState {
    /// The pane's own pick; `inherit` follows its workspace.
    var pin: BackdropPin = .inherit
    /// The pane's marker tint.
    var tint: PaneTint?
    /// The pane's copy of the art and its tint, under everything.
    var artView: WindowMaterialView?
    /// The plain background over the window's art (the pane's own `none`).
    var coverView: NSView?
    /// The marker tint over the pane.
    var tintView: PaneTintView?
}
