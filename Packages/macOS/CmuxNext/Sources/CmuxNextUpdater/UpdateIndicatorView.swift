public import AppKit
import CmuxNextDesign
import QuartzCore

/// The rail's update circle, like the Codex app's: a disc in the theme's
/// highlight color. A waiting update shows a thin download-tray glyph and
/// installs on click; checking, downloading and installing show a thin arc
/// in the glyph color (spinning, or filling with download progress). Every
/// layer is a vector shape rasterized at the window's backing scale on a
/// pixel-aligned square, so the disc stays round and sharp. It sits in a
/// rail button slot and takes the rail tiles' hover fill.
@MainActor
public final class UpdateIndicatorView: NSView {
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// A click (the App installs or shows details).
    public var onPress: (() -> Void)?
    /// The circle's right-click menu (Install, Release Notes, Check).
    public var menuProvider: (() -> NSMenu?)?
    public private(set) var phase: UpdateIndicatorPhase = .hidden

    private let disc = CAShapeLayer()
    private let glyph = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var spinning = false
    /// The window's backing scale; layers rasterize at it.
    var backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2 {
        didSet {
            guard backingScale != oldValue else { return }
            applyBackingScale()
            needsLayout = true
        }
    }
    var discFrame: CGRect { disc.frame }
    var ringFrame: CGRect { ring.frame }
    var ringLineWidth: CGFloat { ring.lineWidth }
    var layerContentsScales: [CGFloat] { [disc, glyph, ring].map(\.contentsScale) }

    /// Stroke width of the busy arc and the download glyph, like Codex's.
    static let strokeWidth: CGFloat = 1.25

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for sublayer in [disc, glyph, ring] as [CALayer] { layer?.addSublayer(sublayer) }
        for stroke in [glyph, ring] {
            stroke.fillColor = nil
            stroke.lineCap = .round
            stroke.lineJoin = .round
            stroke.lineWidth = Self.strokeWidth
        }
        applyBackingScale()
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

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { backingScale = scale }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor { backingScale = scale }
    }

    /// Hand-made layers default to 1x: at 2x the disc came out soft and lumpy.
    private func applyBackingScale() {
        for sublayer in [disc, glyph, ring] as [CALayer] { sublayer.contentsScale = backingScale }
    }

    /// The disc's frame in `bounds`: the rail's icon box (like the account
    /// avatar), square, and centered on device pixels at `scale`.
    static func discRect(in bounds: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(scale, 1)
        let side = (min(bounds.width, bounds.height) - Metrics.space2 * 2).rounded()
        let x = ((bounds.midX - side / 2) * scale).rounded() / scale
        let y = ((bounds.midY - side / 2) * scale).rounded() / scale
        return CGRect(x: x, y: y, width: side, height: side)
    }

    override public func layout() {
        super.layout()
        hover.layout()
        let rect = Self.discRect(in: bounds, scale: backingScale)
        let side = rect.width
        let center = CGPoint(x: rect.midX, y: rect.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = rect
        disc.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
        let glyphSide = (side * 0.5 * backingScale).rounded() / backingScale
        glyph.frame = CGRect(x: center.x - glyphSide / 2, y: center.y - glyphSide / 2, width: glyphSide, height: glyphSide)
        glyph.path = Self.downloadGlyphPath(side: glyphSide)
        // Codex's arc spans about two fifths of the disc.
        let ringSide = (side * 0.42 * backingScale).rounded() / backingScale
        ring.bounds = CGRect(x: 0, y: 0, width: ringSide, height: ringSide)
        ring.position = center
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: Self.strokeWidth / 2, dy: Self.strokeWidth / 2), transform: nil)
        CATransaction.commit()
    }

    override public func updateLayer() {
        // Phase changes swap layers at once: an implicit fade left the old
        // ring showing during a note.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            disc.fillColor = Palette.highlight.cgColor
            ring.strokeColor = Palette.highlightText.cgColor
            glyph.strokeColor = Palette.highlightText.cgColor
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
            ring.strokeEnd = 0.8
        case .hidden, .available, .ready, .note:
            showsRing = false
        }
        let spins = phase.spins
        glyph.isHidden = showsRing || !phase.showsCircle
        ring.isHidden = !showsRing
        if spins != spinning {
            spinning = spins
            if spins, let spin = Motion.spinAnimation() { ring.add(spin, forKey: "spin") } else { ring.removeAnimation(forKey: "spin") }
        }
        CATransaction.commit()
        hover.refresh(animated: true)
    }

    /// A down arrow into an open tray, stroked thin (top-down coordinates:
    /// the view is flipped).
    private static func downloadGlyphPath(side: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * side, y: y * side) }
        path.move(to: point(0.5, 0.08))
        path.addLine(to: point(0.5, 0.62))
        path.move(to: point(0.28, 0.42))
        path.addLine(to: point(0.5, 0.64))
        path.addLine(to: point(0.72, 0.42))
        path.move(to: point(0.1, 0.62))
        path.addLine(to: point(0.1, 0.9))
        path.addLine(to: point(0.9, 0.9))
        path.addLine(to: point(0.9, 0.62))
        return path
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
