import AppKit
import CmuxNextDesign
import QuartzCore

/// One palette in the group editor's palette row: a smudged marble of the palette's colors (Leo 2026-11-06: "you
/// pick this circle, right? And it's like this ball of colors ... if you think of, like, a smudged marble, that's
/// what I like"), its name under it. Glass is a clear ball. The chosen palette gets a ring in the primary text color.
final class GroupPaletteMarbleView: NSView {
    let palette: GroupPalette
    var isChosen = false { didSet { if oldValue != isChosen { updateColors() } } }
    var onPick: ((GroupPalette) -> Void)?
    private let ball = MarbleBallView()
    private let ring = CALayer()
    private let caption = ChromeLabel(labelWithString: "")
    private var isHovered = false { didSet { if oldValue != isHovered { updateColors() } } }

    init(palette: GroupPalette) {
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        ring.borderWidth = Metrics.space1 * 0.75
        ring.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "borderColor": NSNull()]
        layer?.addSublayer(ring)
        caption.font = Typography.caption
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.stringValue = GroupEditorStrings.paletteName(palette)
        for view in [ball, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let side = Self.ballSide
        NSLayoutConstraint.activate([
            ball.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space1),
            ball.centerXAnchor.constraint(equalTo: centerXAnchor),
            ball.widthAnchor.constraint(equalToConstant: side),
            ball.heightAnchor.constraint(equalToConstant: side),
            caption.topAnchor.constraint(equalTo: ball.bottomAnchor, constant: Metrics.space1 + 1),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(GroupEditorStrings.paletteName(palette))
        setAccessibilityHelp(GroupEditorStrings.paletteHelp)
        setAccessibilityIdentifier("cmux.sidebar.groupEditor.palette.\(palette.rawValue)")
        themedToolTip = GroupEditorStrings.paletteHelp
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The ball's side: a little larger than a color dot, so a palette reads as more than one color.
    static var ballSide: CGFloat { Metrics.iconSize + Metrics.space3 }

    override func layout() {
        super.layout()
        let frame = ball.frame.insetBy(dx: -(Metrics.space1 - 1), dy: -(Metrics.space1 - 1))
        ring.frame = frame
        ring.cornerRadius = frame.width / 2
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// The palette's colors may have changed (a theme, the desktop picture): draw the ball again.
    func refresh() { updateColors() }

    private func updateColors() {
        performWithTheme {
            let tokens = themeTokens
            ball.colors = palette == .glass ? [] : GroupColor.marble(palette, tokens: tokens, wallpaper: BackdropImageStore.shared.desktop.tint)
            ball.ink = tokens.textPrimary
            ball.isDark = tokens.isDark
            caption.textColor = isChosen ? Palette.textPrimary : Palette.textSecondary
            ring.borderColor = (isChosen ? Palette.textPrimary : (isHovered ? Palette.separator : NSColor.clear)).cgColor
        }
        setAccessibilityValue(isChosen ? 1 : 0)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(palette) }
    }

    override func accessibilityPerformPress() -> Bool {
        onPick?(palette)
        return true
    }
}

/// The marble itself: each color a soft radial smudge around the ball, over the first color, then a highlight and a
/// rim, as glass. No colors draws the clear glass ball.
final class MarbleBallView: NSView {
    var colors: [ThemeRGB] = [] { didSet { if oldValue != colors { needsDisplay = true } } }
    var ink = ThemeRGB.white { didSet { if oldValue != ink { needsDisplay = true } } }
    var isDark = true { didSet { if oldValue != isDark { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        if let base = colors.first {
            context.setFillColor(base.nsColor.cgColor)
            context.fill(rect)
            // The smudges: each color fades out from a point on a ring around the center, so neighbors blend.
            for (index, color) in colors.enumerated().dropFirst() {
                let angle = 2 * Double.pi * Double(index) / Double(colors.count) + 0.6
                let point = CGPoint(x: center.x + cos(angle) * radius * 0.6, y: center.y + sin(angle) * radius * 0.6)
                let solid = color.withAlpha(1).nsColor.cgColor, clear = color.withAlpha(0).nsColor.cgColor
                guard let smudge = CGGradient(colorsSpace: space, colors: [solid, solid, clear] as CFArray, locations: [0, 0.25, 1])
                else { continue }
                context.drawRadialGradient(smudge, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius * 0.85, options: [])
            }
        } else {
            // Glass: the ink at a breath, so the clear ball still shows over the bubble.
            context.setFillColor(ink.withAlpha(isDark ? 0.08 : 0.05).nsColor.cgColor)
            context.fill(rect)
        }
        // The light from the top left, and a shade toward the bottom right: a ball, not a disc.
        let light = [NSColor.white.withAlphaComponent(colors.isEmpty ? 0.35 : 0.5).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
                     NSColor.black.withAlphaComponent(colors.isEmpty ? 0.06 : 0.16).cgColor] as CFArray
        if let highlight = CGGradient(colorsSpace: space, colors: light, locations: [0, 0.45, 1]) {
            let origin = CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.3)
            context.drawRadialGradient(highlight, startCenter: origin, startRadius: 0, endCenter: origin, endRadius: radius * 1.4, options: [])
        }
        context.restoreGState()
        context.setStrokeColor(ink.withAlpha(colors.isEmpty ? 0.35 : 0.18).nsColor.cgColor)
        context.setLineWidth(Metrics.dividerThickness)
        context.strokeEllipse(in: rect)
    }
}
