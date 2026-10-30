import AppKit
import GhosttyNextKit
import QuartzCore

/// A view's root layer and Ghostty surface as its ``TerminalScaleTarget``. The view that owns this target
/// owns the surface until its deinit hands it to ``TerminalSurfaceTeardown``, which frees it later on main.
@MainActor
final class GhosttyScaleTarget: TerminalScaleTarget {
    /// SAFETY: the owning view's surface, freed only after that view's deinit (``TerminalSurfaceTeardown``),
    /// and the deinit releases this target first; every call arrives on the main actor while the view lives.
    @safe private let surface: ghostty_surface_t?
    /// The view whose root layer Ghostty's renderer reads its scale from.
    private weak var view: NSView?

    /// `surface` and `view` are the owning view's (TerminalSurfaceView.scaleTarget).
    init(surface: ghostty_surface_t?, view: NSView) {
        // SAFETY: the owning view's surface, handed to this target for the view's life (`surface`'s note).
        self.surface = unsafe surface
        self.view = view
    }

    var rootLayerScale: CGFloat? { view?.layer?.contentsScale }

    func setRootLayerScale(_ scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view?.layer?.contentsScale = scale
        // The cursor layer shows Ghostty's cell pixels at the same scale (``TerminalCursorLayer/setScale(_:)``).
        (view as? TerminalSurfaceView)?.cursorLayer?.setScale(scale)
        CATransaction.commit()
    }

    func setContentScale(_ scale: CGSize) {
        guard let surface else { return }
        // SAFETY: the owning view's live surface (`surface`'s note).
        unsafe ghostty_surface_set_content_scale(surface, scale.width, scale.height)
    }

    func setDisplayID(_ id: UInt32) {
        guard let surface else { return }
        // SAFETY: as in setContentScale(_:).
        unsafe ghostty_surface_set_display_id(surface, id)
    }
}
