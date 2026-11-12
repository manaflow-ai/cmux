import AppKit
import CmuxNextDesign
import QuartzCore

/// The "+" after the last tab. Mouse handling lives in the strip.
final class NewTabButtonView: NSView {
    var showsChevron = false {
        didSet {
            setAccessibilityRole(showsChevron ? .popUpButton : .button)
            needsLayout = true
        }
    }
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateColors(animated: true)
            onHoverChange?(isHovered)
            if isHovered {
                if themedToolTip != nil { themedToolTipShortcut = shortcut?() }
            }
        }
    }
    var isPressed = false { didSet { if oldValue != isPressed { updateColors(animated: false) } } }
    /// Held only by this button's menu, including accessibility invocation without hover.
    var isMenuOpen = false { didSet { if oldValue != isMenuOpen { updateColors(animated: false) } } }
    var onPress: (() -> Void)?
    /// The trailing controls' shared hover look (``TabTrailingButtons/hoverStyle``): a circle under the + in
    /// `circle`; the glyph's ink alone otherwise (the + never drew a plate).
    var hoverStyle: ChromeHoverStyle = .glyph {
        didSet { if oldValue != hoverStyle { needsLayout = true; updateColors(animated: false) } }
    }
    /// The + is the leading segment of the split look's `+ ⌄` (``TabTrailingButtons/split``): its fill spans its
    /// frame with the group's leading corners rounded, and shows softly while the ⌄ is hovered.
    var splitSegment = false {
        didSet { if oldValue != splitSegment { needsLayout = true; updateColors(animated: false) } }
    }
    /// The ⌄ beside it is under the pointer (the split look's shared hover).
    var siblingHovered = false {
        didSet { if oldValue != siblingHovered { updateColors(animated: true) } }
    }
    /// The pointer came onto (true) or left (false) the +.
    var onHoverChange: ((Bool) -> Void)?
    /// The new tab action's shortcut as the person sees it ("⌘T"), read on hover so a rebinding
    /// shows at once; the tooltip draws it after its text.
    var shortcut: (() -> String?)?
    /// VoiceOver moved its focus onto (true) or off (false) the plus.
    var onAccessibilityFocus: ((Bool) -> Void)?

    private let fillLayer = CALayer()
    private let glyphLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        fillLayer.cornerRadius = Metrics.tabCornerRadius
        fillLayer.cornerCurve = Metrics.tabCornerCurve
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        glyphLayer.fillColor = nil
        glyphLayer.lineWidth = Metrics.addGlyphLineWidth
        glyphLayer.lineCap = .round
        glyphLayer.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(glyphLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.axNewTab)
        setAccessibilityIdentifier("cmux.tabs.newTab")
        // The plus says what it does and that holding it opens the new tab menu (`TabNewTabHold`).
        themedToolTip = Strings.newTabHoldHint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        onAccessibilityFocus?(accessibilityFocused)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let square = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let split = splitSegment && !showsChevron
        // The split look's + is a tab's height (``frameHeight``): its fill is its whole frame, a tab's band.
        fillLayer.frame = split ? bounds : showsChevron ? bounds.insetBy(dx: Metrics.space1, dy: (bounds.height - side) / 2) : square
        // A circle in the circles look, one diameter with the ⌄ and the ⋮; else the tabs' shape. The split look
        // rounds only the group's leading corners: the ⌄ beside it rounds the trailing ones.
        fillLayer.cornerRadius = split ? Self.splitCornerRadius
            : hoverStyle == .circle && !showsChevron ? side / 2 : Metrics.tabCornerRadius
        fillLayer.cornerCurve = Metrics.tabCornerCurve
        fillLayer.maskedCorners = split ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : Self.allCorners
        glyphLayer.frame = bounds
        // The add buttons' one + (`Metrics.addGlyphExtent`), the sidebar's New Workspace size.
        let arm = Metrics.addGlyphExtent / 2
        let scale = window?.backingScaleFactor ?? 2
        glyphLayer.contentsScale = scale
        // In the split look the + leans half a step toward its ⌄, which leans back, so the pair reads as one control.
        let lean = split ? Metrics.space1 / 2 : 0
        let center = CGPoint(x: ((square.midX - (showsChevron ? Metrics.space2 : 0) + lean) * scale).rounded() / scale, y: (square.midY * scale).rounded() / scale)
        let path = CGMutablePath()
        path.addPath(CGPath.addGlyph(center: center, scale: scale))
        if showsChevron {
            let x = center.x + arm + Metrics.space3
            let half = Self.chevronHalfWidth, rise = Self.chevronRise
            path.move(to: CGPoint(x: x - half, y: center.y - rise / 2))
            path.addLine(to: CGPoint(x: x, y: center.y + rise / 2))
            path.addLine(to: CGPoint(x: x + half, y: center.y - rise / 2))
        }
        glyphLayer.path = path
        CATransaction.commit()
    }

    override func updateLayer() {
        updateColors(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors(animated: false)
    }

    private func updateColors(animated: Bool) {
        let hovering = isHovered || isMenuOpen
        let pressed = isPressed || isMenuOpen
        let token = animated ? ChromeHover.fade(showing: hovering || pressed, pressed: pressed) : nil
        // An instant change also ends a fill still easing in.
        if (token.map(Motion.tabs.duration) ?? 0) == 0 { fillLayer.removeAnimation(forKey: "backgroundColor") }
        Motion.tabs.transaction(token) {
            performWithTheme {
                // New-tab is a plain glyph action. Its hover/press state is carried by the glyph,
                // never by a rounded plate behind the +; the circles look adds one circle. Its own menu holds the pressed state.
                fillLayer.backgroundColor = splitSegment && !showsChevron
                    ? Self.splitFill(hovering: hovering, pressed: pressed, siblingHovered: siblingHovered)?.cgColor
                    : hoverStyle == .circle ? ChromeHover.fillColor(.init(hovering: hovering, pressed: pressed))?.cgColor : nil
                glyphLayer.strokeColor = Self.glyphInk(hovering: hovering, pressed: pressed).cgColor
                glyphLayer.lineWidth = Self.glyphLineWidth(pressed: pressed)
            }
        }
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard showsChevron else { return false }
        onPress?()
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]

    /// A split segment's fill (cmux classic's): the hover fill under the pointer or the pressed fill while held, half
    /// the hover fill while the other segment is hovered, else none. Call inside the view's theme scope.
    static func splitFill(hovering: Bool, pressed: Bool, siblingHovered: Bool) -> NSColor? {
        if hovering || pressed { return ChromeHover.fillColor(.init(hovering: hovering, pressed: pressed)) }
        guard siblingHovered else { return nil }
        return ChromeHover.fillColor(.init(hovering: true)).map { $0.withAlphaComponent($0.alphaComponent / 2) }
    }

    /// The split control's corner: a tab's (``Metrics/tabCornerRadius``), on a tab's height (``frameHeight``), so the
    /// `+ ⌄` hover reads as a tab, not a pill (Lucas 2026-11-12: "same height and roundness as tabs").
    static var splitCornerRadius: CGFloat { Metrics.tabCornerRadius }

    /// The + button's height in the tab strip: the split look's `+ ⌄` is a tab's height, so its hover fill is a tab's
    /// band; every other look keeps the square button (`side`), centered on the tabs.
    static func frameHeight(split: Bool, side: CGFloat, tabHeight: CGFloat) -> CGFloat { split ? tabHeight : side }

    /// The trailing controls' glyph ink: secondary at rest, primary on hover, the lit ink while pressed or while its
    /// menu is open. The ⌄ beside the + draws with it too. Call inside the view's theme scope.
    static func glyphInk(hovering: Bool, pressed: Bool) -> NSColor {
        pressed ? Palette.litGlyph : (hovering ? Palette.textPrimary : Palette.textSecondary)
    }

    /// The trailing controls' stroke: the +'s, and the ⌄'s so the two read as one weight. Neutral themes can use
    /// the same ink for hover and selection; a heavier stroke keeps a held press visible there too, without a fill.
    static func glyphLineWidth(pressed: Bool) -> CGFloat { pressed ? Metrics.addGlyphPressedLineWidth : Metrics.addGlyphLineWidth }

    /// Half the ⌄'s width: three quarters of the +'s arm (`Metrics.addGlyphExtent`), so it reads as the +'s companion,
    /// not its peer. The ⌄ is half as tall as it is wide (``chevronRise``), the SF Symbol chevron's proportion.
    static var chevronHalfWidth: CGFloat { Metrics.addGlyphExtent / 2 * 0.75 }

    /// The ⌄'s height: its half width, so it is twice as wide as it is tall.
    static var chevronRise: CGFloat { chevronHalfWidth }
}

/// Flipped container with no event handling of its own.
final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
