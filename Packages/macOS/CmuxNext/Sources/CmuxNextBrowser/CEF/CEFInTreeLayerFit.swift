import AppKit
import QuartzCore

/// Keeps an in-tree page's drawing layer the size of its view, in the same layout pass as the view.
///
/// Chromium draws a page with its own compositor through `DisplayCALayerTree`: the `RenderWidgetHostViewCocoa`'s layer
/// holds a geometry-flipped layer, anchored at the bottom left, with the page's `CALayerHost` at that layer's top left.
/// The flipped layer follows the view's layer only by Core Animation autoresizing, which adds each change of the view's
/// size to the layer's current size, rounded. Inside Chromium's own window that layer is rarely used; in tree it draws
/// every page, and panes take half-point sizes every frame of a divider drag, a zoom spring or a window resize. The
/// layer drifted from its view and never came back: on the other Mac (build 17edc4df) a 266.5 x 353.5 page view had it
/// at 290 x 375, so the page drew 21.5 pt above its pane (its top cut off), its bottom 21.5 pt never painted, and each
/// click landed 21.5 pt above what it showed (in-tree-regressions.md bugs 13, 14, 18).
///
/// As the view layer's `layoutManager`, this sets each flipped sublayer's frame to the layer's bounds whenever Core
/// Animation lays the layer out (every bounds change marks it), so the page's top left is the view's top left in every
/// committed frame. It touches only flipped sublayers (Chromium's drawing layer), never adds or removes one.
final class CEFInTreeLayerFit: NSObject, CALayoutManager {
    static let shared = CEFInTreeLayerFit()

    /// Fits `view`'s drawing layer from now on (its layer gets this layout manager), and marks the layer for layout, so
    /// the fit runs in this commit even when Core Animation did not mark it for the bounds change AppKit just made.
    func fit(_ view: NSView?) { // perf-hot: 0.05ms cef-geometry (each in-tree page resize)
        guard let layer = view?.layer else { return }
        guard layer.layoutManager !== self else { return layer.setNeedsLayout() }
        layer.layoutManager = self
        layoutSublayers(of: layer)
    }

    nonisolated func layoutSublayers(of layer: CALayer) {
        let bounds = layer.bounds
        let drift = (layer.sublayers ?? []).filter { $0.isGeometryFlipped && $0.frame != bounds }
        guard !drift.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in drift { sublayer.frame = bounds }
        CATransaction.commit()
    }
}
