import AppKit
import CmuxNextDesign

/// The system material behind a floating pane's see-through background (Debug Settings > Floating Pane >
/// Material): it blurs the panes under the card. A look knob for DEV and NIGHTLY builds: the default is no
/// material, so the card makes this view only while the knob has one. It takes no clicks.
final class FloatingPaneMaterialView: NSView {
    private let effect = NSVisualEffectView() // glass-level-allow: a debug look knob of the floating pane (FloatingPaneTunables.material), off by default, not a surface level
    private var shown: (size: CGSize, corners: FloatingPaneCorners)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `material` in the card's outline. The mask is made again only when the size or a corner changes (each
    /// frame of a resize while the knob has a material).
    func show(_ material: NSVisualEffectView.Material, corners: FloatingPaneCorners) {
        if effect.material != material { effect.material = material }
        let size = bounds.size
        guard shown?.size != size || shown?.corners != corners, size.width > 0, size.height > 0 else { return }
        shown = (size, corners)
        effect.maskImage = Self.mask(size: size, corners: corners)
    }

    /// The outline as a mask image. Not bound to the main actor: AppKit calls the drawing block when it draws
    /// the image, on the thread that draws.
    private nonisolated static func mask(size: CGSize, corners: FloatingPaneCorners) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Alpha-only coverage of the mask: this colour is never displayed.
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(corners.path(in: rect))
            context.fillPath()
            return true
        }
    }
}
