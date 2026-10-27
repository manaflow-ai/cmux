import AppKit

/// Holds presented overlays; flipped so overlay frames read top-down in tests and logs.
final class OverlayContainerView: NSView {
    nonisolated override var isFlipped: Bool { false }
    /// Its host reads the overlays' sizes after each layout pass. Auto Layout marks this view for layout
    /// when it solves a new frame for a content held here (a SwiftUI popover that grew).
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// The container fills the whole layer: only what it holds takes the mouse, never the empty container,
    /// or the topmost one would take every click of the layers below it (an agent cursor tag, a popover).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Clips a `.pane` overlay to its pane minus the occluders (a mask with holes).
final class OverlayClipView: NSView {
    /// Its host reads the overlay's size after each layout pass, as ``OverlayContainerView/onLayout``:
    /// this view, not the container, holds a `.pane` overlay's content.
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // A clipping container: nothing of its own to draw.
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The parts of the clip that show (this view's coordinates); `whole`
    /// when no occluder touches the clip (no mask).
    func setVisibleRects(_ rects: [NSRect], whole: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !whole else {
            layer.mask = nil
            return
        }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = CGMutablePath()
        for rect in rects { path.addRect(rect) }
        mask.frame = bounds
        mask.fillRule = .nonZero
        mask.path = path
        layer.mask = mask
    }
}

/// A scrim over the whole window under a dimming overlay, in the theme's ``Scrim`` strength.
final class OverlayScrimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
        updateLayer()
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let alpha = performWithTheme { (ThemeContext.active ?? ThemeScope.app.tokens).scrimAlpha }
        layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // invalidate: the appearance changed; the colors resolve again.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The scrim takes clicks so nothing below reacts while a modal shows.
    override func mouseDown(with event: NSEvent) {}
}
