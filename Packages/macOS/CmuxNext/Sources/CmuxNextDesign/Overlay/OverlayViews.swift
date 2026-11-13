import AppKit

/// Holds presented overlays; flipped so overlay frames read top-down in tests and logs.
final class OverlayContainerView: NSView {
    nonisolated override var isFlipped: Bool { false }

    /// A presented view's click regions in this view's coordinates (a dialog's card), nil when the
    /// whole view takes clicks. Set by the host.
    var clickRegions: (NSView) -> [NSRect]? = { _ in nil }

    /// A view takes only the clicks in its click region; the rest go to the views under it, so a
    /// dialog's transparent area never covers an older dialog's card (review 32 of #37296).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        for view in subviews.reversed() where !view.isHidden {
            if let regions = clickRegions(view), !regions.contains(where: { $0.contains(local) }) { continue }
            if let hit = view.hitTest(local) { return hit }
        }
        return frame.contains(point) ? self : nil
    }
}

/// Clips a `.pane` overlay to its pane minus the occluders (a mask with holes).
final class OverlayClipView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The scrim takes clicks so nothing below reacts while a modal shows.
    override func mouseDown(with event: NSEvent) {}
}
