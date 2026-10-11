import AppKit
import CmuxNextDesign
import QuartzCore

/// The row being dragged: a live row view on a flat themed card with a
/// shadow (the sidebar has no glass).
/// Multi-item drags show stacked cards behind it and a count badge.
final class DragLiftView: NSView {
    private let card = NSView()
    private let content: NSView
    private var stack: [NSView] = []
    private let countBadge = NSTextField(labelWithString: "")
    private let badgeBackground = NSView()
    private var lifted = false

    init(content: NSView, count: Int) {
        self.content = content
        super.init(frame: .zero)
        card.wantsLayer = true
        card.layer?.cornerRadius = SidebarStyle.rowCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        wantsLayer = true
        layer?.masksToBounds = false

        for depth in (1..<max(1, min(count, 3))).reversed() {
            let back = NSView()
            back.wantsLayer = true
            back.layer?.cornerRadius = SidebarStyle.rowCornerRadius
            back.layer?.cornerCurve = .continuous
            back.layer?.borderWidth = Metrics.lineWidth(0.5)
            back.identifier = NSUserInterfaceItemIdentifier("\(depth)")
            addSubview(back)
            stack.append(back)
        }
        addSubview(card)
        card.addSubview(content)
        content.autoresizingMask = [.width, .height]

        if count > 1 {
            badgeBackground.wantsLayer = true
            badgeBackground.layer?.cornerCurve = .continuous
            countBadge.stringValue = "\(count)"
            countBadge.font = SidebarStyle.badgeFont
            countBadge.alignment = .center
            addSubview(badgeBackground)
            addSubview(countBadge)
        }
        layer?.shadowOpacity = 0
        layer?.shadowOffset = CGSize(width: 0, height: Metrics.space1)
        layer?.shadowRadius = Metrics.space2
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        card.frame = bounds
        content.frame = card.bounds
        for back in stack {
            let depth = CGFloat(Int(back.identifier?.rawValue ?? "1") ?? 1)
            back.frame = bounds.insetBy(dx: Metrics.space2 * depth, dy: 0).offsetBy(dx: 0, dy: Metrics.space2 * depth)
        }
        let size = countBadge.intrinsicContentSize
        let h = SidebarStyle.badgeHeight + Metrics.space1
        let w = max(h, size.width + Metrics.space4)
        badgeBackground.frame = NSRect(x: bounds.maxX - w + Metrics.space3, y: -h / 2, width: w, height: h)
        badgeBackground.layer?.cornerRadius = h / 2
        countBadge.frame = NSRect(x: badgeBackground.frame.minX, y: badgeBackground.frame.midY - size.height / 2, width: w, height: size.height)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: SidebarStyle.rowCornerRadius, cornerHeight: SidebarStyle.rowCornerRadius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            card.layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.shadowColor = Palette.shadow.cgColor
            for back in stack {
                back.layer?.backgroundColor = Palette.elevatedBackground.withAlphaComponent(0.85).cgColor
                back.layer?.borderColor = Palette.separator.cgColor
            }
            badgeBackground.layer?.backgroundColor = Palette.textPrimary.cgColor
            countBadge.textColor = Palette.textOnPrimary
        }
    }

    /// Lifted: deeper shadow. Landing: shadow fades as the card settles.
    func setLifted(_ lifted: Bool, animated: Bool) {
        guard lifted != self.lifted, let layer else { return }
        self.lifted = lifted
        let opacity: Float = lifted ? 0.28 : 0
        let radius = lifted ? Metrics.space5 : Metrics.space2
        let offset = CGSize(width: 0, height: lifted ? Metrics.space3 : Metrics.space1)
        guard animated else {
            Motion.transaction(nil) {
                layer.shadowOpacity = opacity
                layer.shadowRadius = radius
                layer.shadowOffset = offset
            }
            return
        }
        // Each property fades from what is on screen, so a quick drop during
        // the lift continues from the current shadow.
        Motion.set(layer, "shadowOpacity", to: opacity, fade: .lift)
        Motion.set(layer, "shadowRadius", to: radius, fade: .lift)
        Motion.set(layer, "shadowOffset", to: NSValue(size: offset), fade: .lift)
    }

    /// Dims the card when the current hover position cannot accept the drop.
    func setRefused(_ refused: Bool) {
        let target: CGFloat = refused ? 0.55 : 1
        guard alphaValue != target else { return }
        Motion.animate(.hover, in: self) { animator().alphaValue = target }
    }
}
