public import AppKit
public import CmuxNextDesignTokens

/// Sidebar Thunderdome E (Leo 2026-11-05: "we can get artsy ... extravagant ... maximalist"): the
/// corner where the vertical sidebar meets the horizontal tab strip at the main pane's top-leading
/// corner, drawn as one of `CornerChaosStyle` (Debug Settings `chrome.cornerChaos`, off by default).
///
/// One layer-backed view over the window root (placed by `SidebarCornerChaos`), above the sidebar and below the titlebar controls.
/// It takes no clicks, owns no layout of anything else and moves no frame: every variant is shape
/// layers placed from the card's and the selected row's frames. A selection change moves its marks
/// with `Motion.sidebar` (a spring on `position`, compositor-driven, no per-frame layout), so the
/// master and sidebar animation switches, the speed and Reduce Motion all apply; with animation off
/// it lands in one frame. Every circle has an even point diameter on a whole-pixel center, and
/// every straight stroke sits on the pixel grid, so it stays crisp at 1x and 2x.
public final class CornerChaosView: NSView {
    /// What the view reads from its window, each time it places the marks.
    public struct Geometry: Equatable {
        /// The main pane card, in this view's (flipped) coordinates.
        public var card: CGRect
        public var cardRadius: CGFloat
        /// The selected workspace's row, in this view's coordinates; nil when none is drawn.
        public var row: CGRect?
        public var rowRadius: CGFloat
        public var title: String?
        public var color: GroupColor?

        public init(card: CGRect, cardRadius: CGFloat, row: CGRect?, rowRadius: CGFloat, title: String?, color: GroupColor?) {
            (self.card, self.cardRadius, self.row, self.rowRadius, self.title, self.color) = (card, cardRadius, row, rowRadius, title, color)
        }
    }

    public var style: CornerChaosStyle = .off {
        didSet { if style != oldValue { rebuild(animated: false) } }
    }

    private var geometry: Geometry?
    /// The workspace the seal shows (title and color), so a change of it pops the seal.
    private var sealKey: String?
    // Liquid bridge.
    private let liquid = CAShapeLayer()
    // Circuit: a soft glow and a sharp core, each a radial gradient masked by the same path.
    private let circuitGlow = CAGradientLayer()
    private let circuitGlowMask = CAShapeLayer()
    private let circuitCore = CAGradientLayer()
    private let circuitCoreMask = CAShapeLayer()
    private let circuitNode = CAShapeLayer()
    // Bracket.
    private let bracket = CAShapeLayer()
    private let bracketPointer = CAShapeLayer()
    // Seal.
    private let sealOrbit = CAShapeLayer()
    private let seal = CAShapeLayer()
    private let sealLetter = CATextLayer()

    private var allLayers: [CALayer] {
        [liquid, circuitGlow, circuitCore, circuitNode, bracket, bracketPointer, sealOrbit, seal]
    }

    private func layers(of style: CornerChaosStyle) -> [CALayer] {
        switch style {
        case .off: []
        case .liquid: [liquid]
        case .circuit: [circuitGlow, circuitCore, circuitNode]
        case .bracket: [bracket, bracketPointer]
        case .seal: [sealOrbit, seal]
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for sublayer in allLayers {
            sublayer.isHidden = true
            sublayer.actions = Self.noActions
            layer?.addSublayer(sublayer)
        }
        circuitGlow.type = .radial
        circuitCore.type = .radial
        circuitGlow.mask = circuitGlowMask
        circuitCore.mask = circuitCoreMask
        for mask in [circuitGlowMask, circuitCoreMask] {
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.lineCap = .round
            mask.lineJoin = .round
        }
        circuitGlowMask.lineWidth = 6
        circuitCoreMask.lineWidth = 2
        bracket.fillColor = nil
        bracket.lineWidth = 2
        bracket.lineJoin = .miter
        bracket.lineCap = .butt
        sealOrbit.fillColor = nil
        sealOrbit.lineWidth = 1
        sealLetter.alignmentMode = .center
        sealLetter.actions = Self.noActions
        seal.addSublayer(sealLetter)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Implicit actions off: every change either lands in one frame or goes through `Motion`.
    private static let noActions: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
                                                            "hidden": NSNull(), "opacity": NSNull(), "transform": NSNull(),
                                                            "contents": NSNull(), "string": NSNull(), "colors": NSNull()]

    override public var isFlipped: Bool { true }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild(animated: false)
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild(animated: false)
    }

    /// Places the marks for `geometry`. A move of the selected row alone (a selection change, a
    /// scroll) springs the marks to it when `animated`; anything else lands at once.
    public func update(_ geometry: Geometry?, animated: Bool) {
        guard geometry != self.geometry else { return }
        let onlyRowMoved = geometry.map { new in self.geometry.map { $0.card == new.card && $0.cardRadius == new.cardRadius } ?? false } ?? false
        self.geometry = geometry
        rebuild(animated: animated && onlyRowMoved)
    }

    // MARK: Drawing

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    /// `value` on the device pixel grid.
    private func px(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    private func rebuild(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Hide what this style does not draw; its own layers keep their state, so a mark that shows
        // springs from where it is.
        let own = layers(of: style)
        for sublayer in allLayers where !own.contains(where: { $0 === sublayer }) { sublayer.isHidden = true }
        guard style != .off, let geometry, !geometry.card.isEmpty else {
            for sublayer in own { sublayer.isHidden = true }
            return
        }
        // A mark with no row to point at hides until there is one.
        if geometry.row == nil { for sublayer in [liquid, circuitNode, bracketPointer] { sublayer.isHidden = true } }
        performWithTheme {
            switch style {
            case .off: break
            case .liquid: drawLiquid(geometry, animated: animated)
            case .circuit: drawCircuit(geometry, animated: animated)
            case .bracket: drawBracket(geometry, animated: animated)
            case .seal: drawSeal(geometry, animated: animated)
            }
        }
    }

    /// Moves `layer` to `position`: a `Motion.sidebar` spring from where it shows now when
    /// `animated`, else at once.
    private func place(_ layer: CALayer, at position: CGPoint, animated: Bool) {
        if animated, !layer.isHidden {
            Motion.sidebar.set(layer, "position", to: NSValue(point: position), spring: .move)
        } else {
            layer.removeAnimation(forKey: "position")
            layer.position = position
        }
    }

    /// The gutter between the sidebar and the card (at least 4 pt, so the marks have a lane).
    private var gutter: CGFloat { max(4, Metrics.mainPaneGutter) }

    // MARK: Liquid

    /// The selected row's fill flows across the gutter into the card: a band as tall as the row,
    /// pinched at its middle like two drops about to merge, that flares into the card's edge with
    /// concave fillets (an inverted corner, as a browser's selected tab meets its toolbar, turned on
    /// its side). The shape leaves out the row and the card, so no fill is drawn twice.
    private func drawLiquid(_ geometry: Geometry, animated: Bool) {
        guard let row = geometry.row, row.maxX < geometry.card.minX else {
            liquid.isHidden = true
            return
        }
        let rowRadius = min(geometry.rowRadius, row.height / 2)
        let edge = geometry.card.minX
        let flare = min(row.height / 2, max(6, gutter + 2))
        // Local coordinates: x as in the view, y from the row's top.
        let height = row.height
        let start = row.maxX - rowRadius
        let width = max(0, edge - flare - start)
        let pinch = height * 0.16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start, y: 0))
        path.addCurve(to: CGPoint(x: edge - flare, y: 0), control1: CGPoint(x: start + width * 0.45, y: pinch),
                      control2: CGPoint(x: edge - flare - width * 0.3, y: pinch))
        path.addQuadCurve(to: CGPoint(x: edge, y: -flare), control: CGPoint(x: edge, y: 0))
        path.addLine(to: CGPoint(x: edge + 1, y: -flare))
        path.addLine(to: CGPoint(x: edge + 1, y: height + flare))
        path.addLine(to: CGPoint(x: edge, y: height + flare))
        path.addQuadCurve(to: CGPoint(x: edge - flare, y: height), control: CGPoint(x: edge, y: height))
        path.addCurve(to: CGPoint(x: start, y: height), control1: CGPoint(x: edge - flare - width * 0.3, y: height - pinch),
                      control2: CGPoint(x: start + width * 0.45, y: height - pinch))
        path.closeSubpath()
        // Leave out the row's own rounded fill and everything from the card's edge on.
        let rowShape = CGPath(roundedRect: CGRect(x: row.minX, y: 0, width: row.width, height: height),
                              cornerWidth: rowRadius, cornerHeight: rowRadius, transform: nil)
        let cardSide = CGPath(rect: CGRect(x: edge, y: -flare - 2, width: 4, height: height + 2 * flare + 4), transform: nil)
        liquid.path = path.subtracting(rowShape).subtracting(cardSide)
        liquid.fillColor = Palette.selectionFill.cgColor
        liquid.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: 0)
        liquid.anchorPoint = .zero
        place(liquid, at: CGPoint(x: 0, y: px(row.minY)), animated: animated)
        liquid.isHidden = false
    }

    // MARK: Circuit

    /// One line that runs up the gutter beside the sidebar, turns the corner concentric with the
    /// card's, and runs along the gutter above the tab strip: the vertical and the horizontal as a
    /// single path. A radial gradient lights it brightest at the tangent point and lets both ends
    /// fade out, with a soft glow under a sharp core; a node rides the line at the selected row.
    private func drawCircuit(_ geometry: Geometry, animated: Bool) {
        let card = geometry.card, inset = px(gutter / 2)
        let lineX = card.minX - inset, lineY = card.minY - inset
        let radius = geometry.cardRadius + inset
        let path = CGMutablePath()
        path.move(to: CGPoint(x: lineX, y: card.maxY))
        path.addLine(to: CGPoint(x: lineX, y: lineY + radius))
        path.addArc(tangent1End: CGPoint(x: lineX, y: lineY), tangent2End: CGPoint(x: lineX + radius, y: lineY), radius: radius)
        path.addLine(to: CGPoint(x: card.maxX, y: lineY))
        let accent = Palette.accent
        let reach: CGFloat = 520
        let center = CGPoint(x: (lineX + radius * 0.3) / max(1, bounds.width), y: (lineY + radius * 0.3) / max(1, bounds.height))
        let end = CGPoint(x: center.x + reach / max(1, bounds.width), y: center.y + reach / max(1, bounds.height))
        for (gradient, mask, alphas) in [(circuitGlow, circuitGlowMask, [0.45, 0.18, 0]), (circuitCore, circuitCoreMask, [1, 0.6, 0])] {
            gradient.frame = bounds
            gradient.startPoint = center
            gradient.endPoint = end
            gradient.colors = alphas.map { accent.withAlphaComponent($0).cgColor }
            gradient.locations = [0, 0.35, 1]
            mask.frame = bounds
            mask.path = path
            gradient.isHidden = false
        }
        circuitGlowMask.lineWidth = 6
        // The node: an 8 pt dot on the line, ringed in the chrome color so it reads as a joint.
        guard let row = geometry.row else { return }
        let diameter: CGFloat = 8
        circuitNode.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        circuitNode.path = CGPath(ellipseIn: circuitNode.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        circuitNode.fillColor = accent.cgColor
        circuitNode.strokeColor = Palette.windowBackground.cgColor
        circuitNode.lineWidth = 2
        circuitNode.shadowColor = accent.cgColor
        circuitNode.shadowOpacity = 0.9
        circuitNode.shadowRadius = 4
        circuitNode.shadowOffset = .zero
        place(circuitNode, at: CGPoint(x: lineX, y: px(row.midY)), animated: animated)
        circuitNode.isHidden = false
    }

    // MARK: Bracket

    /// A HUD corner, as a game's target reticle or a Teenage Engineering panel: two legs in the
    /// gutter joined by a 45° chamfer tangent to the card's corner, with measured ticks that step
    /// out along each leg and a chamfered pointer that marks the selected row.
    private func drawBracket(_ geometry: Geometry, animated: Bool) {
        let card = geometry.card, inset = px(gutter / 2)
        let lineX = card.minX - inset, lineY = card.minY - inset
        // The chamfer touches the concentric arc of radius cardRadius + inset at 45°.
        let arcRadius = geometry.cardRadius + inset
        let cut = px(max(4, 2 * geometry.cardRadius - arcRadius * 2.squareRoot() + 2 * inset))
        let leg: CGFloat = 64, tick: CGFloat = 4, step: CGFloat = 8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: lineX, y: lineY + cut + leg))
        path.addLine(to: CGPoint(x: lineX, y: lineY + cut))
        path.addLine(to: CGPoint(x: lineX + cut, y: lineY))
        path.addLine(to: CGPoint(x: lineX + cut + leg, y: lineY))
        // Ticks past each leg's end: three marks, shorter as they go, out of the corner's way.
        for index in 0..<3 {
            let offset = cut + leg + step * CGFloat(index + 1)
            let length = tick - CGFloat(index)
            path.move(to: CGPoint(x: lineX, y: lineY + offset))
            path.addLine(to: CGPoint(x: lineX, y: lineY + offset + length))
            path.move(to: CGPoint(x: lineX + offset, y: lineY))
            path.addLine(to: CGPoint(x: lineX + offset + length, y: lineY))
        }
        bracket.frame = bounds
        bracket.path = path
        bracket.strokeColor = Palette.accent.cgColor
        bracket.isHidden = false
        // The pointer: a chamfered arrow in the gutter at the selected row, its tip on the card's edge.
        guard let row = geometry.row else { return }
        let width = max(4, px(gutter)), half: CGFloat = 5
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 0, y: 0))
        arrow.addLine(to: CGPoint(x: width - 2, y: 0))
        arrow.addLine(to: CGPoint(x: width, y: 2))
        arrow.addLine(to: CGPoint(x: width, y: 2 * half - 2))
        arrow.addLine(to: CGPoint(x: width - 2, y: 2 * half))
        arrow.addLine(to: CGPoint(x: 0, y: 2 * half))
        arrow.addLine(to: CGPoint(x: 2, y: half))
        arrow.closeSubpath()
        bracketPointer.bounds = CGRect(x: 0, y: 0, width: width, height: 2 * half)
        bracketPointer.anchorPoint = CGPoint(x: 1, y: 0.5)
        bracketPointer.path = arrow
        bracketPointer.fillColor = Palette.accent.cgColor
        place(bracketPointer, at: CGPoint(x: card.minX, y: px(row.midY)), animated: animated)
        bracketPointer.isHidden = false
    }

    // MARK: Seal

    /// The corner as a live element: a round seal on the tangent point, filled with the selected
    /// workspace's color (else the accent) and lettered with its initial, ringed in the chrome color
    /// so it reads as the joint between the sidebar and the strip, with a hairline orbit around it.
    /// A new workspace pops it (`Motion.sidebar`, `appear`).
    private func drawSeal(_ geometry: Geometry, animated: Bool) {
        let card = geometry.card, inset = gutter / 2
        let arcRadius = geometry.cardRadius + inset
        let arcCenter = CGPoint(x: card.minX + geometry.cardRadius, y: card.minY + geometry.cardRadius)
        let diagonal = arcRadius / 2.squareRoot()
        let center = CGPoint(x: px(arcCenter.x - diagonal), y: px(arcCenter.y - diagonal))
        let diameter: CGFloat = 20, ring: CGFloat = 2, orbit: CGFloat = 30
        seal.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        seal.position = center
        seal.path = CGPath(ellipseIn: seal.bounds.insetBy(dx: ring / 2, dy: ring / 2), transform: nil)
        let fill = geometry.color?.swatch ?? Palette.accent
        seal.fillColor = fill.cgColor
        seal.strokeColor = Palette.windowBackground.cgColor
        seal.lineWidth = ring
        sealOrbit.bounds = CGRect(x: 0, y: 0, width: orbit, height: orbit)
        sealOrbit.position = center
        sealOrbit.path = CGPath(ellipseIn: sealOrbit.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        sealOrbit.strokeColor = fill.withAlphaComponent(0.45).cgColor
        let font = Typography.system(size: TypeScale.caption, weight: TypeScale.strong)
        let letter = geometry.title.flatMap { $0.trimmingCharacters(in: .whitespaces).first }.map { String($0).uppercased() } ?? ""
        let lineHeight = ceil(font.ascender - font.descender)
        sealLetter.font = font
        sealLetter.fontSize = font.pointSize
        sealLetter.string = letter
        sealLetter.foregroundColor = NSColor.white.cgColor
        sealLetter.contentsScale = scale
        sealLetter.frame = CGRect(x: 0, y: px((diameter - lineHeight) / 2), width: diameter, height: lineHeight)
        let key = "\(geometry.title ?? "")|\(geometry.color?.rawValue ?? "")"
        let changed = sealKey != nil && sealKey != key
        sealKey = key
        seal.isHidden = false
        sealOrbit.isHidden = false
        if changed {
            Motion.sidebar.set(seal, "transform.scale", to: 1, spring: .appear, from: 0.82)
        }
    }
}
