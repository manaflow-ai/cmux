#if canImport(UIKit)
import QuartzCore
import UIKit

/// A self-owned drag-selection highlight, layered ABOVE the Metal terminal
/// surface so inbound render-grid frames never overwrite it.
///
/// The iPad terminal mirrors the Mac's ghostty surface: the Mac owns the
/// "real" selection and streams already-highlighted cells back over the
/// render-grid, so the on-device ghostty selection is invisible (each inbound
/// frame repaints the Metal layer and erases it). This overlay sidesteps that
/// entirely — it draws the selected cell rects into a `CAShapeLayer` that sits
/// on top of the renderer layer and is therefore the source of truth for the
/// drag highlight. Geometry is computed by ``TerminalSelectionGeometry`` and
/// pushed in via ``update(rects:scale:)``.
final class TerminalSelectionOverlay {
    /// One translucent fill spanning every selected row rect. A single shape
    /// layer (vs. one layer per row) keeps the highlight to one compositor node
    /// and one fill pass regardless of how many rows are selected.
    private let shapeLayer = CAShapeLayer()

    /// Whether a non-empty highlight is currently shown.
    private(set) var isActive = false

    init(color: CGColor) {
        shapeLayer.name = "cmux.selectionOverlay"
        // Above the Metal renderer layer (zPosition 0) so render-grid repaints
        // can't cover it; below the cursor overlay (1001) so the cursor stays
        // visible. The selection rects live in the terminal body and never
        // overlap the bottom chrome, so sharing the chrome's z-band is moot.
        shapeLayer.zPosition = 1000
        shapeLayer.fillColor = color
        // Disable implicit animations: the path/visibility must track the drag
        // frame-for-frame, not cross-fade a frame behind the finger.
        shapeLayer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
            "fillColor": NSNull(),
        ]
        shapeLayer.isHidden = true
    }

    /// Attach the highlight layer to `host` (the surface view's backing layer).
    /// Idempotent — re-attaching to the same host is a no-op.
    func attach(to host: CALayer) {
        if shapeLayer.superlayer !== host {
            host.addSublayer(shapeLayer)
        }
    }

    /// Swap the highlight tint (e.g. when the terminal config's
    /// `selection-background` resolves after first paint).
    func setColor(_ color: CGColor) {
        shapeLayer.fillColor = color
    }

    /// Replace the highlight with the union of `rects` (point space). An empty
    /// `rects` clears the highlight.
    func update(rects: [CGRect], scale: CGFloat) {
        guard !rects.isEmpty else {
            clear()
            return
        }
        let path = CGMutablePath()
        for rect in rects {
            path.addRect(rect)
        }
        shapeLayer.contentsScale = scale
        shapeLayer.path = path
        shapeLayer.isHidden = false
        isActive = true
    }

    /// Hide and forget the current highlight.
    func clear() {
        shapeLayer.path = nil
        shapeLayer.isHidden = true
        isActive = false
    }
}
#endif
