import AppKit

/// Draws the chrome text on screen again after ``ProcessFontSmoothing/chrome`` changes
/// (`appearance.fontSmoothing`, https://github.com/manaflow-ai/cmux/issues/44844).
///
/// ``ChromeLabel`` and ``ChromeTextLayer`` keep their glyph images per stem weight
/// (``GlyphMask/weight(of:smoothing:)``), which names the smoothing too, so each only needs to
/// look at its weight again: a label redraws in `updateLayer`, a text layer swaps to a kept image
/// or draws its line. Nothing else changes: no layout, no color.
@MainActor
enum ChromeTextRefresh {
    /// Every ``ChromeLabel`` and ``ChromeTextLayer`` in the app's windows.
    static func all() {
        for window in NSApp?.windows ?? [] {
            guard let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { continue }
            refresh(root)
        }
    }

    /// The chrome text in `layer` and every layer under it (a ``ChromeLabel``'s layer has the
    /// label as its delegate).
    static func refresh(_ layer: CALayer) {
        if let label = layer.delegate as? ChromeLabel {
            label.needsDisplay = true
        } else if let text = layer as? ChromeTextLayer {
            text.smoothingDidChange()
            return
        }
        for sublayer in layer.sublayers ?? [] { refresh(sublayer) }
        if let mask = layer.mask { refresh(mask) }
    }
}
