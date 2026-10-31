import AppKit
import QuartzCore

// A strip whose pane springs to a new width (a split, a close, a zoom): the pane lays it out once at its
// width at rest and cuts it to the pane's width on each frame (`shownWidth`), so no frame lays a tab out.
extension TabStripView {
    /// Cuts the strip to ``shownWidth`` (a mask on its layer), or shows all of it.
    func applyShownWidth() {
        guard let layer, let shownWidth, shownWidth < bounds.width - 0.5 else {
            if let shownWidthMask, layer?.mask === shownWidthMask { layer?.mask = nil }
            return
        }
        let mask = shownWidthMask ?? CALayer()
        shownWidthMask = mask
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = CGRect(x: 0, y: 0, width: max(0, shownWidth), height: bounds.height)
        if layer.mask !== mask { layer.mask = mask }
        CATransaction.commit()
    }
}
