import AppKit

/// The transient bubble that carries sent text from the composer into its transcript slot.
///
/// Position, size, and corner radius animate together on one spring (0.35 s response,
/// 0.8 damping). The text is laid out once at its final wrap width, so it only moves; a
/// composer-colored copy cross-fades into the bubble-colored copy. The owner reveals the
/// real cell and removes this view in the same transaction, so nothing flickers.
@MainActor
final class AcpmuxMorphBubbleView: NSView {
    private let fill = CALayer()
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let finalLabel = NSTextField(wrappingLabelWithString: "")

    override var isFlipped: Bool { true }

    init(text: String, theme: AcpmuxChatTheme, from start: CGRect, textWidth: CGFloat) {
        super.init(frame: start)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.backgroundColor = theme.userBubble.cgColor
        fill.cornerRadius = 8
        fill.opacity = 0
        fill.frame = bounds
        layer?.addSublayer(fill)
        for (label, color) in [(sourceLabel, theme.foreground), (finalLabel, theme.userText)] {
            label.stringValue = text
            label.font = theme.bodyFont
            label.textColor = color
            label.isSelectable = false
            label.drawsBackground = false
            label.isBordered = false
            label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = textWidth
            let height = (label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height).map { ceil($0) } ?? 20
            label.frame = CGRect(origin: .zero, size: CGSize(width: textWidth + 4, height: height))
            addSubview(label)
        }
        finalLabel.alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Springs into `target` (this view's superview coordinates), then calls `completion`.
    func morph(to target: CGRect, textOrigin: CGPoint, completion: @escaping @MainActor () -> Void) {
        let start = frame
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        // Final model values first, then springs from the old values.
        frame = target
        fill.frame = CGRect(origin: .zero, size: target.size)
        fill.cornerRadius = 17.5
        fill.opacity = 1
        for label in [sourceLabel, finalLabel] { label.frame.origin = textOrigin }
        sourceLabel.alphaValue = 0
        finalLabel.alphaValue = 1

        let hostLayer = layer!
        add(spring("position", from: Self.position(of: start, in: hostLayer), to: Self.position(of: target, in: hostLayer)), to: hostLayer)
        add(spring("bounds.size", from: NSValue(size: start.size), to: NSValue(size: target.size)), to: hostLayer)
        add(spring("bounds.size", from: NSValue(size: start.size), to: NSValue(size: target.size)), to: fill)
        add(spring("position", from: NSValue(point: CGPoint(x: start.width / 2, y: start.height / 2)),
                   to: NSValue(point: CGPoint(x: target.width / 2, y: target.height / 2))), to: fill)
        add(spring("cornerRadius", from: 8 as NSNumber, to: 17.5 as NSNumber), to: fill)
        let fillFade = CABasicAnimation(keyPath: "opacity")
        fillFade.fromValue = 0
        fillFade.toValue = 1
        fillFade.duration = 0.12
        fill.add(fillFade, forKey: "fade")
        for (label, from, to) in [(sourceLabel, 1.0, 0.0), (finalLabel, 0.0, 1.0)] {
            guard let labelLayer = label.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = 0.16
            labelLayer.add(fade, forKey: "fade")
            add(spring("position", from: NSValue(point: CGPoint(x: labelLayer.position.x - textOrigin.x, y: labelLayer.position.y - textOrigin.y)),
                       to: NSValue(point: labelLayer.position)), to: labelLayer)
        }
        CATransaction.commit()
    }

    private func spring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        AcpmuxTranscriptRowCellView.applyResponse(animation)
        return animation
    }

    private func add(_ animation: CAAnimation, to layer: CALayer) {
        layer.add(animation, forKey: (animation as? CAPropertyAnimation)?.keyPath)
    }

    /// The layer position for a frame, honoring the host's anchor point and geometry.
    private static func position(of rect: CGRect, in layer: CALayer) -> NSValue {
        let anchor = layer.anchorPoint
        let y: CGFloat
        if let superlayer = layer.superlayer, !superlayer.isGeometryFlipped {
            y = superlayer.bounds.height - rect.maxY + rect.height * anchor.y
        } else {
            y = rect.minY + rect.height * anchor.y
        }
        return NSValue(point: CGPoint(x: rect.minX + rect.width * anchor.x, y: y))
    }
}
