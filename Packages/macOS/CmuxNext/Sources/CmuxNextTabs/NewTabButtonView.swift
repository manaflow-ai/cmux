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
    var onPress: (() -> Void)?
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
        fillLayer.cornerRadius = Metrics.itemCornerRadius
        fillLayer.cornerCurve = .continuous
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        glyphLayer.fillColor = nil
        glyphLayer.lineWidth = Metrics.space1 * 0.7
        glyphLayer.lineCap = .round
        glyphLayer.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
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

    /// The pointing hand over the plus, as over every clickable chrome control (`ClickableButton`).
    /// A cursor rect works with no hit testing; it covers only the plus's visible rect, and none
    /// while the plus is hidden or scrolled out of view.
    override func resetCursorRects() {
        if let rect = ClickableButton.cursorRect(of: self) { addCursorRect(rect, cursor: .pointingHand) }
    }

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
        glyphLayer.frame = bounds
        let arm = Metrics.space2 + Metrics.space1 / 2
        let scale = window?.backingScaleFactor ?? 2
        glyphLayer.contentsScale = scale
        let center = CGPoint(x: ((square.midX - (showsChevron ? Metrics.space2 : 0)) * scale).rounded() / scale, y: (square.midY * scale).rounded() / scale)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        if showsChevron {
            let x = center.x + arm + Metrics.space3
            path.move(to: CGPoint(x: x - Metrics.space1, y: center.y - Metrics.space1 / 2))
            path.addLine(to: CGPoint(x: x, y: center.y + Metrics.space1 / 2))
            path.addLine(to: CGPoint(x: x + Metrics.space1, y: center.y - Metrics.space1 / 2))
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
        let token = animated ? ChromeHover.fade(showing: isHovered || isPressed, pressed: isPressed) : nil
        // An instant change also ends a fill still easing in.
        if (token.map(Motion.tabs.duration) ?? 0) == 0 { fillLayer.removeAnimation(forKey: "backgroundColor") }
        Motion.tabs.transaction(token) {
            performWithTheme {
                fillLayer.backgroundColor = ChromeHover.fillColor(.init(hovering: isHovered, pressed: isPressed))?.cgColor
                glyphLayer.strokeColor = (isHovered ? Palette.textPrimary : Palette.textSecondary).cgColor
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
}

/// Flipped container with no event handling of its own.
final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
