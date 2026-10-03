public import AppKit
import CmuxNextDesign
import QuartzCore

/// The rail's update circle, like the Codex app's: a disc in the theme's
/// highlight color. A waiting update shows a download glyph and installs on
/// click; checking, downloading and installing show a ring in the glyph
/// color (spinning, or filling with download progress). It sits in a rail
/// button slot and takes the rail tiles' hover fill.
@MainActor
public final class UpdateIndicatorView: NSView {
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// A click (the App installs or shows details).
    public var onPress: (() -> Void)?
    /// The circle's right-click menu (Install, Release Notes, Check).
    public var menuProvider: (() -> NSMenu?)?
    public private(set) var phase: UpdateIndicatorPhase = .hidden

    private let disc = CAShapeLayer()
    private let glyph = CALayer()
    private let ring = CAShapeLayer()
    private var spinning = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for sublayer in [disc, glyph, ring] as [CALayer] { layer?.addSublayer(sublayer) }
        ring.fillColor = nil
        ring.lineCap = .round
        glyph.contentsGravity = .resizeAspect
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var wantsUpdateLayer: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        phase.showsCircle ? super.hitTest(point) : nil
    }

    public func show(_ phase: UpdateIndicatorPhase, toolTip: String?) {
        self.phase = phase
        // A note keeps the slot empty: no hover, clicks or VoiceOver button there.
        self.toolTip = phase.showsCircle ? toolTip : nil
        setAccessibilityElement(phase.showsCircle)
        setAccessibilityLabel(toolTip)
        if !phase.showsCircle { hover.state = .init() }
        needsLayout = true
        needsDisplay = true
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The disc's diameter: the rail's icon box, like the account avatar.
    var discDiameter: CGFloat { (min(bounds.width, bounds.height) - Metrics.space2 * 2).rounded() }

    override public func layout() {
        super.layout()
        hover.layout()
        let side = discDiameter
        let rect = CGRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = rect
        disc.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
        let glyphSide = (side * 0.5).rounded()
        glyph.frame = CGRect(x: rect.midX - glyphSide / 2, y: rect.midY - glyphSide / 2, width: glyphSide, height: glyphSide)
        let ringSide = (side * 0.5).rounded()
        ring.bounds = CGRect(x: 0, y: 0, width: ringSide, height: ringSide)
        ring.position = CGPoint(x: rect.midX, y: rect.midY)
        ring.lineWidth = max(1.5, (side / 14).rounded())
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: ring.lineWidth / 2, dy: ring.lineWidth / 2), transform: nil)
        CATransaction.commit()
    }

    override public func updateLayer() {
        performWithTheme {
            disc.fillColor = Palette.highlight.cgColor
            ring.strokeColor = Palette.highlightText.cgColor
            glyph.contents = Self.downloadGlyph(side: glyph.bounds.width, color: Palette.highlightText)
        }
        disc.opacity = hover.state.pressed ? 0.8 : 1
        disc.isHidden = !phase.showsCircle
        let showsRing: Bool
        switch phase {
        case .downloading(let progress?):
            showsRing = true
            ring.strokeEnd = max(0.05, progress)
        case .checking, .downloading, .installing:
            showsRing = true
            ring.strokeEnd = 0.75
        case .hidden, .ready, .note:
            showsRing = false
        }
        let spins = phase.spins
        glyph.isHidden = showsRing || !phase.showsCircle
        ring.isHidden = !showsRing
        if spins != spinning {
            spinning = spins
            if spins, let spin = Motion.spinAnimation() { ring.add(spin, forKey: "spin") } else { ring.removeAnimation(forKey: "spin") }
        }
        hover.refresh(animated: true)
    }

    private static func downloadGlyph(side: CGFloat, color: NSColor) -> NSImage? {
        guard side > 0 else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: side, weight: .bold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    // MARK: Mouse

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        change(&hover.state)
        needsDisplay = true
    }

    override public func mouseEntered(with event: NSEvent) {
        guard phase.showsCircle else { return }
        changeHover { $0.hovering = true }
    }
    override public func mouseExited(with event: NSEvent) { changeHover { $0.hovering = false; $0.pressed = false } }
    override public func mouseDown(with event: NSEvent) { changeHover { $0.pressed = true } }

    override public func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        changeHover { $0.pressed = false }
        if inside, phase.showsCircle { onPress?() }
    }

    override public func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override public func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
