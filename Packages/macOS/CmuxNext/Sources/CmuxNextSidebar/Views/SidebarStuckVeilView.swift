import AppKit
import CmuxNextDesign
import QuartzCore

/// What a stuck project header stands on: the gallery's pick `veil` (cmux #40299, `ProjectCapsSticky.gallery.tsx`;
/// Leo 2026-11-10). The sidebar's own glass, its tone at 90% over a blur of the rows passing under the header, then a
/// 12 pt fade from that tone into the rows below. No line and no shadow (design/sidebar.md: the Blocks style draws no
/// line). Under Reduce Transparency the tone is opaque and nothing blurs. It spans the list's width, from the header's
/// top to the fade's end, and takes no clicks: the header over it does. Hidden while no header is stuck, so a header
/// at rest draws exactly as before.
final class SidebarStuckVeilView: NSView {
    /// The fade under the header into the rows (the gallery's `--pcd-fade`).
    static let fadeHeight: CGFloat = 12
    /// The share of the sidebar's tone the veil keeps (the gallery's `--pcd-veil`: the tone at 90%).
    static let toneShare: Double = 0.9
    /// The blur of the rows under the header (internal so tests can read it).
    let blur = NSVisualEffectView() // glass-level-allow: the stuck header's veil blurs the sidebar's own rows within the window, under the sidebar tone; no tint level of its own
    /// The sidebar's tone over the blur, as tall as the header.
    let tone = CALayer()
    /// The tone fading to clear below the header.
    let fade = CAGradientLayer()
    private var headerHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        blur.blendingMode = .withinWindow
        blur.material = .sidebar
        blur.state = .active
        blur.autoresizingMask = []
        addSubview(blur)
        for layer in [tone, fade] as [CALayer] {
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "colors": NSNull()]
            self.layer?.addSublayer(layer)
        }
        ReduceTransparency.shared.register(repainting: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// The fade's direction depends on the flips of the layers above it.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Puts the veil under a header drawn at `header` (list coordinates) in a list `width` wide.
    func place(under header: NSRect, width: CGFloat) {
        let frame = NSRect(x: 0, y: header.minY, width: width, height: header.height + Self.fadeHeight)
        if self.frame != frame { self.frame = frame }
        if headerHeight != header.height {
            headerHeight = header.height
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let band = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        blur.frame = band
        tone.frame = band
        fade.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        // Location 0 is the fade's top on screen, under the header.
        let top: CGFloat = ScrollEdgeFadeView.rendersTopDown(fade) ? 0 : 1
        fade.startPoint = CGPoint(x: 0.5, y: top)
        fade.endPoint = CGPoint(x: 0.5, y: 1 - top)
        CATransaction.commit()
    }

    override func updateLayer() {
        performWithTheme {
            let opaque = ReduceTransparency.shared.isEnabled
            let ground = themeTokens.sidebarBackground
            let shown = opaque ? ground.withAlpha(1) : ground.withAlpha(ground.alpha * Self.toneShare)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            blur.isHidden = opaque
            tone.backgroundColor = shown.cgColor
            fade.colors = [shown.cgColor, shown.withAlpha(0).cgColor]
            CATransaction.commit()
        }
    }
}
