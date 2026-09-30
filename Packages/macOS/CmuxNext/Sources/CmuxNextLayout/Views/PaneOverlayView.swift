import AppKit
import CmuxNextDesign
import QuartzCore

/// Non-interactive pane overlay, framed on the pane's cell: the subtle
/// hairline border, the focus ring (subtle gray, never blue) and the
/// inactive dim, all on the rounded content rect. The ring replaces the
/// border while it shows, so the two never double up.
final class PaneOverlayView: NSView {
    private let border = CALayer()
    private let ring = CALayer()
    private let dimLayer = CALayer()
    private var padding: CGFloat = 0
    private var cornerRadius: CGFloat = 0
    private var ringWidth: CGFloat = 1
    private var wantsRing = false
    private var wantsBorder = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for sublayer in [dimLayer, border, ring] {
            sublayer.opacity = 0
            layer?.addSublayer(sublayer)
        }
        ring.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the ring is showing (for `debug.layers`).
    var showsRing: Bool { ring.opacity > 0 }
    /// Whether the hairline border is showing (for `debug.layers`).
    var showsBorder: Bool { border.opacity > 0 }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func setShape(padding: CGFloat, cornerRadius: CGFloat) {
        guard padding != self.padding || cornerRadius != self.cornerRadius else { return }
        self.padding = padding
        self.cornerRadius = cornerRadius
        layoutLayers()
    }

    private func layoutLayers() {
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        let rect = PaneChromeGeometry.contentRect(forCell: bounds, style: style)
        let radius = PaneChromeGeometry.cornerRadius(for: rect, style: style)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [dimLayer, border, ring] {
            sublayer.frame = rect
            sublayer.cornerRadius = radius
        }
        border.borderWidth = PaneChromeGeometry.hairlineWidth(scale: scale)
        ring.borderWidth = ringWidth
        CATransaction.commit()
    }

    func update(showsRing: Bool, dim: CGFloat, ringWidth: CGFloat, showsBorder: Bool, animated: Bool) {
        applyColors()
        self.ringWidth = ringWidth
        wantsRing = showsRing
        wantsBorder = showsBorder
        Motion.transaction(animated ? .focus : nil) {
            ring.borderWidth = ringWidth
            ring.opacity = showsRing ? 1 : 0
            border.opacity = showsBorder && !showsRing ? 1 : 0
            dimLayer.opacity = Float(dim)
        }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.borderColor = Palette.focusRing.withAlphaComponent(0.55).cgColor
            border.borderColor = Palette.paneBorder.cgColor
            dimLayer.backgroundColor = Palette.contentBackground.withAlphaComponent(1).cgColor
        }
    }
}
