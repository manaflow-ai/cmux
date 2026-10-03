import CoreGraphics
import QuartzCore

/// One transcript row as plain Core Animation layers: the content bitmap,
/// the outgoing gradient fill under it, the receipt cross-fade and typing
/// dots. `layer` carries the row's position springs; `content` its fades.
@MainActor
final class RowLayer {
    let layer = CALayer()
    let content = CALayer()
    private(set) var spec: RowSpec?
    private(set) var key = ""
    /// Ledger entries already added to this row's layers.
    var applied = Set<Int>()

    private let fillContainer = CALayer()
    private let fillGradient = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    let bitmap = CALayer()
    let typingContainer = CALayer()
    private var dots: [CALayer] = []
    let receiptOld = CALayer()
    private var metrics = Metrics(width: 0)
    private var viewportHeight: CGFloat = 0
    private var paletteGeneration = -1

    static let noActions: [String: CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "path": NSNull(), "hidden": NSNull(),
        "opacity": NSNull(), "transform": NSNull(), "zPosition": NSNull(), "backgroundColor": NSNull(),
        "colors": NSNull(), "locations": NSNull(), "sublayerTransform": NSNull(), "anchorPoint": NSNull(),
        "frame": NSNull(), "mask": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    init() {
        for l in [layer, content, fillContainer, fillGradient, fillMask, bitmap, typingContainer, receiptOld] {
            l.actions = RowLayer.noActions
            l.contentsScale = Canvas.scale
        }
        fillContainer.addSublayer(fillGradient)
        fillContainer.mask = fillMask
        layer.addSublayer(content)
        content.addSublayer(fillContainer)
        content.addSublayer(bitmap)
        typingContainer.isHidden = true
        typingContainer.anchorPoint = CGPoint(x: 0, y: 1)
        let b = RowArt.typingBubble
        typingContainer.bounds = CGRect(x: 0, y: 0, width: RowArt.typingWidth, height: b.maxY + 8)
        typingContainer.position = CGPoint(x: 0, y: b.maxY + 8)
        for i in 0..<3 {
            let dot = CALayer()
            let highlight = CALayer()
            for l in [dot, highlight] {
                l.actions = RowLayer.noActions
                l.cornerRadius = 3.25
            }
            highlight.opacity = 0
            dot.addSublayer(highlight)
            let c = RowArt.typingDotCenter(i)
            dot.frame = CGRect(x: c.x - 3.25, y: c.y - 3.25, width: 6.5, height: 6.5)
            highlight.frame = dot.bounds
            typingContainer.addSublayer(dot)
            dots.append(dot)
        }
        content.addSublayer(typingContainer)
    }

    /// Back to the pool: no animations, no row.
    func prepareForReuse() {
        clearAnimations()
        applied = []
        key = ""
    }

    private func clearAnimations() {
        for l in [layer, content, fillContainer, bitmap, typingContainer, receiptOld] { l.removeAllAnimations() }
        dots.forEach { $0.sublayers?.first?.removeAllAnimations() }
    }

    /// Shows `spec` laid out for `metrics`. The bitmap comes from the content
    /// cache, so a row whose content did not change is not redrawn; a new
    /// bitmap is drawn off the main actor and installed when it is ready.
    func configure(_ spec: RowSpec, metrics: Metrics, bitmaps: RowBitmaps, viewportHeight: CGFloat) {
        if key != spec.key { clearAnimations(); applied = []; key = spec.key }
        let paletteChanged = paletteGeneration != bitmaps.paletteGeneration
        guard paletteChanged || self.spec != spec || self.metrics != metrics || self.viewportHeight != viewportHeight else { return }
        if paletteChanged {
            applyPalette(bitmaps.palette)
            paletteGeneration = bitmaps.paletteGeneration
            bitmap.contentsScale = bitmaps.scale
            receiptOld.contentsScale = bitmaps.scale
        }
        self.spec = spec
        self.metrics = metrics
        self.viewportHeight = viewportHeight
        let frame = RowArt.frame(spec, metrics: metrics)
        bitmap.frame = frame
        // A miss draws off the main actor; the result lands here if the row still shows this spec.
        let generation = paletteGeneration
        bitmap.contents = bitmaps.image(for: spec, size: frame.size) { [weak self] image in
            guard let self, self.spec == spec, self.paletteGeneration == generation else { return }
            self.bitmap.contents = image
        }
        let typing = if case .typing = spec.kind { true } else { false }
        typingContainer.isHidden = !typing
        if typing {
            if bitmap.superlayer !== typingContainer { typingContainer.insertSublayer(bitmap, at: 0) }
        } else if bitmap.superlayer !== content {
            content.insertSublayer(bitmap, above: fillContainer)
        }
        configureFill(spec)
        receiptOld.contents = nil
    }

    private func applyPalette(_ palette: HomePalette) {
        fillGradient.colors = palette.outgoingGradient.map(\.color.cgColor)
        fillGradient.locations = palette.outgoingGradient.map { NSNumber(value: Double($0.location)) }
        for dot in dots {
            dot.backgroundColor = palette.typingDot.cgColor
            dot.sublayers?.first?.backgroundColor = palette.typingDotHighlight.cgColor
        }
    }

    private func configureFill(_ spec: RowSpec) {
        guard let p = spec.partRow, p.outgoing else {
            fillContainer.isHidden = true
            return
        }
        fillContainer.isHidden = false
        let body = RowArt.bodyRect(spec, metrics: metrics)
        fillContainer.frame = CGRect(x: 0, y: 0, width: metrics.width, height: spec.height + 2 * Style.rowMargin)
        fillMask.frame = body
        fillMask.path = BubblePath.make(body: CGRect(origin: .zero, size: body.size), outgoing: true, tail: p.tail)
        fillGradient.frame = CGRect(x: 0, y: -windowY, width: metrics.width, height: viewportHeight)
    }

    /// Viewport y of the row's top: the outgoing fill shades with it.
    var windowY: CGFloat = 0 {
        didSet {
            guard windowY != oldValue, !fillContainer.isHidden else { return }
            fillGradient.frame.origin.y = -windowY
        }
    }

    /// The previous receipt, drawn so it can fade out over the new one.
    func setPreviousReceipt(_ image: CGImage?, frame: CGRect) {
        receiptOld.frame = frame
        if receiptOld.superlayer == nil { content.insertSublayer(receiptOld, above: bitmap) }
        receiptOld.contents = image
        receiptOld.opacity = Animate.hiddenOpacity
    }

    var hasTypingDots: Bool { dots.first?.sublayers?.first?.animation(forKey: "dots") != nil }

    func stopTypingDots() {
        dots.forEach { $0.sublayers?.first?.removeAnimation(forKey: "dots") }
    }

    func startTypingDots(begin: CFTimeInterval) {
        for (i, dot) in dots.enumerated() {
            guard let highlight = dot.sublayers?.first else { continue }
            Animate.typingDot(highlight, index: i, begin: begin)
        }
    }
}
