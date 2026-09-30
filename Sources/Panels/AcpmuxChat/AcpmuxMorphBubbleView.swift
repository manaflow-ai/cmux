import AppKit

/// The transient bubble that carries sent text from the composer into its transcript slot.
///
/// The view covers the whole pane and never moves; only layers animate, so AppKit never
/// applies an end-state frame early. A flight layer sits at the text's origin and carries
/// the text and the bubble outline:
/// - it starts where the text sits in the composer, with the outline tight around the
///   text's glyph bounds;
/// - its horizontal and vertical positions follow two springs with slightly different
///   responses, so it travels a slight curve instead of a straight line;
/// - the outline springs from the tight rectangle to the final tailed bubble (the same path
///   builder the cell uses, so the shapes match at hand-off);
/// - the text is the row's own finished layout, so it lands exactly on the cell's glyphs; a
///   composer-colored copy cross-fades into the bubble-colored one.
/// Every animation holds its end value until the owner hides the overlay and reveals the
/// real cell in one transaction.
@MainActor
final class AcpmuxMorphBubbleView: NSView {
    private let flight = CALayer()
    private let shape = CAShapeLayer()
    private let sourceText = AcpmuxTextLayoutLayer()
    private let finalText = AcpmuxTextLayoutLayer()
    /// The text's inset inside the final bubble and the bubble's frame, for retargeting.
    private var textInset: CGPoint = .zero
    private var endTarget: CGRect = .zero

    static let responseX = 0.40
    static let responseY = 0.33

    override var isFlipped: Bool { true }

    /// Creates the reusable overlay, hidden. The pane keeps one instance so a send never
    /// inserts a new layer, which can reach the screen a frame after the rest of the update.
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        flight.anchorPoint = .zero
        flight.masksToBounds = false
        flight.addSublayer(shape)
        flight.addSublayer(sourceText)
        flight.addSublayer(finalText)
        layer?.addSublayer(flight)
        autoresizingMask = [.width, .height]
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Flies `finalLayout` (the row's text, bubble-colored) from the composer text at
    /// `start` (its glyph bounds in this view) into the bubble at `target`, then calls
    /// `completion`. `sourceLayout` is the same text in the composer's color.
    func fly(
        sourceLayout: AcpmuxTextLayout,
        finalLayout: AcpmuxTextLayout,
        fillColor: NSColor,
        from start: CGRect,
        to target: CGRect,
        textInset: CGPoint,
        groupedAbove: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        let scale = window?.backingScaleFactor ?? 2
        self.textInset = textInset
        endTarget = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [flight, shape, sourceText, finalText] { layer.removeAllAnimations() }
        flight.position = start.origin
        shape.frame = .zero
        shape.fillColor = fillColor.cgColor
        shape.path = endPath(groupedAbove: groupedAbove)
        for (layer, layout, opacity) in [(sourceText, sourceLayout, Float(0)), (finalText, finalLayout, Float(1))] {
            layer.textLayout = layout
            layer.contentsScale = scale
            layer.frame = CGRect(origin: .zero, size: CGSize(width: layout.container.size.width, height: layout.usedSize.height))
            layer.opacity = opacity
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
        }
        isHidden = false
        CATransaction.commit()

        let startPath = AcpmuxBubblePath(radius: min(8, start.height / 2), groupedRadius: min(8, start.height / 2)).path(
            for: CGRect(origin: .zero, size: start.size), side: .trailing, tail: true,
            groupedAbove: false, groupedBelow: false, tailReach: 0
        )
        let endOrigin = CGPoint(x: target.minX + textInset.x, y: target.minY + textInset.y)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        add(spring("path", from: startPath, to: endPath(groupedAbove: groupedAbove), response: 0.35), to: shape)
        add(spring("position.x", from: start.minX, to: endOrigin.x, response: Self.responseX), to: flight)
        add(spring("position.y", from: start.minY, to: endOrigin.y, response: Self.responseY), to: flight)
        let fillIn = CABasicAnimation(keyPath: "opacity")
        fillIn.fromValue = 0
        fillIn.toValue = 1
        fillIn.duration = 0.08
        add(fillIn, to: shape)
        for (layer, from, to) in [(sourceText, Float(1), Float(0)), (finalText, Float(0), Float(1))] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = 0.16
            add(fade, to: layer)
        }
        CATransaction.commit()
    }

    /// The final outline in the flight layer's coordinates (its origin is the text origin).
    private func endPath(groupedAbove: Bool, target: CGRect? = nil) -> CGPath {
        let target = target ?? endTarget
        let body = CGRect(x: -textInset.x, y: -textInset.y, width: target.width, height: target.height)
        return AcpmuxBubblePath().path(for: body, side: .trailing, tail: true, groupedAbove: groupedAbove, groupedBelow: false)
    }

    /// Redirects a flight in progress to a moved `target` (rows that arrive mid-flight push
    /// the slot up). Each spring restarts from the value on screen, so the bubble bends
    /// toward the new slot instead of jumping; `completion` replaces the earlier one.
    func retarget(to target: CGRect, groupedAbove: Bool, completion: @escaping @MainActor () -> Void) {
        let current = flight.presentation()?.position ?? flight.position
        let currentPath = shape.presentation()?.path
        let endOrigin = CGPoint(x: target.minX + textInset.x, y: target.minY + textInset.y)
        let newPath = endPath(groupedAbove: groupedAbove, target: target)
        endTarget = target
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        add(spring("position.x", from: current.x, to: endOrigin.x, response: Self.responseX), to: flight)
        add(spring("position.y", from: current.y, to: endOrigin.y, response: Self.responseY), to: flight)
        if let currentPath {
            add(spring("path", from: currentPath, to: newPath, response: 0.35), to: shape)
        }
        CATransaction.commit()
    }

    private func spring(_ keyPath: String, from: Any, to: Any, response: Double) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        AcpmuxTranscriptRowCellView.applyResponse(animation, response: response)
        return animation
    }

    private func add(_ animation: CAAnimation, to layer: CALayer) {
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: (animation as? CAPropertyAnimation)?.keyPath)
    }
}

/// Draws a finished ``AcpmuxTextLayout`` as layer content, upright in either geometry.
final class AcpmuxTextLayoutLayer: CALayer {
    var textLayout: AcpmuxTextLayout?

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        textLayout = (layer as? AcpmuxTextLayoutLayer)?.textLayout
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(in context: CGContext) {
        guard let textLayout else { return }
        context.saveGState()
        if !contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        textLayout.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}
