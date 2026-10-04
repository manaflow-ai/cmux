import AppKit

/// Holds presented overlays; flipped so overlay frames read top-down in tests and logs.
final class OverlayContainerView: NSView {
    override var isFlipped: Bool { false }
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

/// A scrim over the whole window under a dimming overlay.
final class OverlayScrimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The scrim takes clicks so nothing below reacts while a modal shows.
    override func mouseDown(with event: NSEvent) {}
}
