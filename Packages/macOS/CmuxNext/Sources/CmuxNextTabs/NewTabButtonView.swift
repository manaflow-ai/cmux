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
        fillLayer.cornerCurve = .circular // Helium's tab: a circular-arc SkRRect, not a squircle
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
        fillLayer.frame = showsChevron ? bounds.insetBy(dx: Metrics.space1, dy: (bounds.height - side) / 2) : square
        // A circle in the circles look, one diameter with the ⌄ and the ⋮; else the tabs' shape.
        fillLayer.cornerRadius = hoverStyle == .circle && !showsChevron ? side / 2 : Metrics.tabCornerRadius
        glyphLayer.frame = bounds
        // The add buttons' one + (`Metrics.addGlyphExtent`), the sidebar's New Workspace size.
        let arm = Metrics.addGlyphExtent / 2
        let scale = window?.backingScaleFactor ?? 2
        glyphLayer.contentsScale = scale
        let center = CGPoint(x: ((square.midX - (showsChevron ? Metrics.space2 : 0)) * scale).rounded() / scale, y: (square.midY * scale).rounded() / scale)
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
                fillLayer.backgroundColor = hoverStyle == .circle
                    ? ChromeHover.fillColor(.init(hovering: hovering, pressed: pressed))?.cgColor : nil
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
