import AppKit
import CmuxNextDesign
import QuartzCore

/// The row being dragged: a live row view on a glass card with a shadow.
/// Multi-item drags show stacked cards behind it and a count badge.
final class DragLiftView: NSView {
    private let card: NSGlassEffectView
    private let content: SidebarRowView
    private var stack: [NSView] = []
    private let countBadge = NSTextField(labelWithString: "")
    private let badgeBackground = NSView()
    private var lifted = false

    init(content: SidebarRowView, count: Int) {
        self.content = content
        let holder = NSView()
        card = Glass.makePanel(content: holder, cornerRadius: SidebarStyle.rowCornerRadius)
        card.translatesAutoresizingMaskIntoConstraints = true
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        for depth in (1..<min(count, 3)).reversed() {
            let back = NSView()
            back.wantsLayer = true
            back.layer?.cornerRadius = SidebarStyle.rowCornerRadius
            back.layer?.cornerCurve = .continuous
            back.layer?.borderWidth = 0.5
            back.identifier = NSUserInterfaceItemIdentifier("\(depth)")
            addSubview(back)
            stack.append(back)
        }
        addSubview(card)
        holder.addSubview(content)
        content.autoresizingMask = [.width, .height]

        if count > 1 {
            badgeBackground.wantsLayer = true
            badgeBackground.layer?.cornerCurve = .continuous
            countBadge.stringValue = "\(count)"
            countBadge.font = SidebarStyle.badgeFont
            countBadge.alignment = .center
            countBadge.textColor = Palette.windowBackground
            addSubview(badgeBackground)
            addSubview(countBadge)
        }
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 4
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        card.frame = bounds
        content.frame = card.contentView?.bounds ?? bounds
        for back in stack {
            let depth = CGFloat(Int(back.identifier?.rawValue ?? "1") ?? 1)
            back.frame = bounds.insetBy(dx: 5 * depth, dy: 0).offsetBy(dx: 0, dy: 4 * depth)
        }
        let size = countBadge.intrinsicContentSize
        let w = max(20, size.width + 10)
        badgeBackground.frame = NSRect(x: bounds.maxX - w + 6, y: -7, width: w, height: 18)
        badgeBackground.layer?.cornerRadius = 9
        countBadge.frame = NSRect(x: badgeBackground.frame.minX, y: badgeBackground.frame.midY - size.height / 2, width: w, height: size.height)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: SidebarStyle.rowCornerRadius, cornerHeight: SidebarStyle.rowCornerRadius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        for back in stack {
            back.layer?.backgroundColor = resolvedCGColor(Palette.windowBackground.withAlphaComponent(0.85))
            back.layer?.borderColor = resolvedCGColor(Palette.separator)
        }
        badgeBackground.layer?.backgroundColor = resolvedCGColor(Palette.textPrimary)
    }

    /// Lifted: deeper shadow. Landing: shadow fades as the card settles.
    func setLifted(_ lifted: Bool, animated: Bool) {
        guard lifted != self.lifted, let layer else { return }
        self.lifted = lifted
        let opacity: Float = lifted ? 0.28 : 0
        let radius: CGFloat = lifted ? 14 : 4
        let offset = CGSize(width: 0, height: lifted ? -8 : -2)
        if animated && !Motion.reduceMotion {
            let group = CAAnimationGroup()
            let o = CABasicAnimation(keyPath: "shadowOpacity")
            o.fromValue = layer.shadowOpacity
            o.toValue = opacity
            let r = CABasicAnimation(keyPath: "shadowRadius")
            r.fromValue = layer.shadowRadius
            r.toValue = radius
            let off = CABasicAnimation(keyPath: "shadowOffset")
            off.fromValue = NSValue(size: layer.shadowOffset)
            off.toValue = NSValue(size: offset)
            group.animations = [o, r, off]
            group.duration = 0.22
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "lift")
        }
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = offset
    }

    /// Dims the card when the current hover position cannot accept the drop.
    func setRefused(_ refused: Bool) {
        let target: CGFloat = refused ? 0.55 : 1
        guard alphaValue != target else { return }
        Motion.animate(Motion.selection) { animator().alphaValue = target }
    }
}
