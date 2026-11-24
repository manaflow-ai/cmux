import AppKit
import QuartzCore

/// Keeps an in-tree page's drawing layers the size of their views, in the same pass that sizes the views.
///
/// Chromium draws a page with its own compositor through `DisplayCALayerTree`: the `RenderWidgetHostViewCocoa`'s layer
/// holds a geometry-flipped layer, anchored at the bottom left, with the page's `CALayerHost` at that layer's top left.
/// The flipped layer follows the view's layer only by Core Animation autoresizing, which adds each change of the view's
/// size to the layer's current size, rounded. In tree it draws every page, and panes take half-point sizes every frame
/// of a divider drag, a zoom spring or a window resize, so the layer drifted from its view and kept the error: on the
/// other Mac (build 17edc4df) a 266.5 x 353.5 page view had it at 290 x 375. The page drew 21.5 pt above its pane (its
/// top cut off), its bottom 21.5 pt was never painted, and each click landed 21.5 pt above what it showed
/// (in-tree-regressions.md bugs 13, 14, 18).
///
/// ``fit(_:)`` runs on the page container whenever it takes a size and whenever the page comes into it: every view in
/// it whose layer holds a flipped layer (each `RenderWidgetHostViewCocoa`, the page's and one a navigation leaves under
/// it) gets its flipped layers set to its layer's bounds, at once, and this object as its layer's `layoutManager`, so a
/// bounds change Chromium makes itself (a renderer that sets its view's frame) is fitted in that layer's next layout.
/// It touches only flipped sublayers, never adds or removes one.
final class CEFInTreeLayerFit: NSObject, CALayoutManager {
    static let shared = CEFInTreeLayerFit()

    /// Fits every page view under `container` now (see the type's notes).
    func fit(_ container: NSView?) { // perf-hot: 0.05ms cef-geometry (each in-tree page resize)
        guard let container else { return }
        fitViews(in: container, depth: 0)
    }

    private func fitViews(in view: NSView, depth: Int) {
        if let layer = view.layer, (layer.sublayers ?? []).contains(where: \.isGeometryFlipped) {
            if layer.layoutManager !== self { layer.layoutManager = self }
            layoutSublayers(of: layer)
        }
        // The container, the page's WebContentsViewCocoa, its RenderWidgetHostViewCocoas.
        guard depth < 3 else { return }
        for subview in view.subviews { fitViews(in: subview, depth: depth + 1) }
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
