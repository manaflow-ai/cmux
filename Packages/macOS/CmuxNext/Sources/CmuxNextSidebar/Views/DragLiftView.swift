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
    let badgeBackground = NSView()
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
        badgeBackground.layer?.cornerRadius = Metrics.chipCornerRadius(height: h)
        countBadge.frame = NSRect(x: badgeBackground.frame.minX, y: badgeBackground.frame.midY - size.height / 2, width: w, height: size.height)
        if lifted {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayerTransform = liftTransform(true)
            CATransaction.commit()
        }
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

    /// Lifted: the one popover shadow (PopupStyle). Landing: it fades as the card settles.
    func setLifted(_ lifted: Bool, animated: Bool) {
        guard lifted != self.lifted, let layer else { return }
        self.lifted = lifted
        let style = PopupStyle.standard
        let opacity: Float = lifted ? Float(style.shadowAlpha) : 0
        let radius = lifted ? style.shadowBlur : Metrics.space2
        let offset = CGSize(width: 0, height: lifted ? style.shadowOffset : Metrics.space1)
        guard animated else {
            Motion.transaction(nil) {
                layer.sublayerTransform = liftTransform(lifted)
                layer.shadowOpacity = opacity
                layer.shadowRadius = radius
                layer.shadowOffset = offset
            }
            return
        }
        // Each property fades from what is on screen, so a quick drop during
        // the lift continues from the current shadow.
        // The card rises in place (DESIGN "Drag feel" 1): a 1.03 scale about its centre, back to 1 as it settles.
        Motion.set(layer, "sublayerTransform", to: NSValue(caTransform3D: liftTransform(lifted)), spring: .move)
        Motion.set(layer, "shadowOpacity", to: opacity, fade: .lift)
        Motion.set(layer, "shadowRadius", to: radius, fade: .lift)
        Motion.set(layer, "shadowOffset", to: NSValue(size: offset), fade: .lift)
    }

    /// Springs the card to `frame` (the shape the drop will take: a list row,
    /// a tile, a group member) with the one move spring (DESIGN "Drag feel" 2).
    /// The model frame changes at once and additive springs carry what is on
    /// screen from the old frame, so the pointer follow (model origin only)
    /// keeps composing with the morph and nothing jumps. Reduce Motion: a
    /// crossfade instead of the shape spring.
    func morph(to frame: NSRect) {
        guard frame != self.frame else { return }
        let layers = [layer, card.layer, content.layer].compactMap { $0 }
        let before = layers.map { ($0, $0.position, $0.bounds.size) }
        Motion.withoutAnimation {
            self.frame = frame
            layoutSubtreeIfNeeded()
        }
        guard Motion.policy.animatesMovement else {
            if let layer { Motion.set(layer, "opacity", to: Float(alphaValue), fade: .crossfade, from: Float(alphaValue) * 0.4) }
            return
        }
        morphs += 1
        for (layer, position, size) in before {
            let dp = NSValue(point: NSPoint(x: position.x - layer.position.x, y: position.y - layer.position.y))
            let ds = NSValue(size: NSSize(width: size.width - layer.bounds.width, height: size.height - layer.bounds.height))
            for (path, delta, zero) in [("position", dp, NSValue(point: .zero)), ("bounds.size", ds, NSValue(size: .zero))] {
                let animation = Motion.springAnimation(.move, path, from: delta, to: zero)
                animation.isAdditive = true
                layer.add(animation, forKey: "morph.\(path).\(morphs)")
            }
        }
    }

    private var morphs = 0

    /// The lifted scale about the card's centre (identity at rest).
    private func liftTransform(_ lifted: Bool) -> CATransform3D {
        guard lifted else { return CATransform3DIdentity }
        let (cx, cy) = (bounds.midX, bounds.midY)
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(cx, cy, 0), Self.liftScale, Self.liftScale, 1), -cx, -cy, 0)
    }

    static let liftScale: CGFloat = 1.03

    /// Dims the card when the current hover position cannot accept the drop.
    func setRefused(_ refused: Bool) {
        let target: CGFloat = refused ? 0.55 : 1
        guard alphaValue != target else { return }
        Motion.animate(.hover, in: self) { animator().alphaValue = target }
    }
}
