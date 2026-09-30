import AppKit

/// The transient bubble that carries sent text from the composer into its transcript slot.
///
/// The view covers the whole pane and never moves; only layers animate, so AppKit never
/// applies an end-state frame early. One spring (0.35 s response, 0.8 damping) drives the
/// bubble outline from the composer's rounded rectangle to the final tailed bubble (the
/// same path builder the cell uses, so the shapes match at hand-off) and moves the text,
/// laid out at its final wrap width. A composer-colored copy of the text cross-fades into
/// the bubble-colored copy. Every animation holds its end value until the owner hides the
/// overlay and reveals the real cell in one transaction.
@MainActor
final class AcpmuxMorphBubbleView: NSView {
    private let shape = CAShapeLayer()
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let finalLabel = NSTextField(wrappingLabelWithString: "")
    private var startRect: CGRect = .zero

    override var isFlipped: Bool { true }

    /// Creates the reusable overlay, hidden. The pane keeps one instance so a send never
    /// inserts a new layer, which can reach the screen a frame after the rest of the update.
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(shape)
        for label in [sourceLabel, finalLabel] {
            label.isSelectable = false
            label.drawsBackground = false
            label.isBordered = false
            label.lineBreakMode = .byWordWrapping
            addSubview(label)
        }
        autoresizingMask = [.width, .height]
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Covers `bounds` and shows the text over the composer text at `start`.
    func prepare(text: String, theme: AcpmuxChatTheme, from start: CGRect, textWidth: CGFloat, in bounds: CGRect) {
        frame = bounds
        startRect = start
        shape.removeAllAnimations()
        shape.frame = CGRect(origin: .zero, size: bounds.size)
        shape.fillColor = theme.userBubble.cgColor
        shape.opacity = 0
        shape.path = startPath(start)
        for (label, color) in [(sourceLabel, theme.foreground), (finalLabel, theme.userText)] {
            label.layer?.removeAllAnimations()
            label.stringValue = text
            label.font = theme.bodyFont
            label.textColor = color
            label.frame.origin = start.origin
        }
        sourceLabel.alphaValue = 1
        finalLabel.alphaValue = 0
        setTextWidth(textWidth)
        isHidden = false
    }

    /// Re-wraps the text at `width`, the final bubble's text width once it is known.
    func setTextWidth(_ width: CGFloat) {
        for label in [sourceLabel, finalLabel] {
            label.preferredMaxLayoutWidth = width
            let height = (label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height).map { ceil($0) } ?? 20
            label.frame = CGRect(origin: label.frame.origin, size: CGSize(width: width + 4, height: height))
        }
    }

    /// The composer-shaped start outline, built with the same elements as the tailed end
    /// outline (a zero-reach tail) so the path interpolates point for point.
    private func startPath(_ rect: CGRect) -> CGPath {
        AcpmuxBubblePath(radius: 8, groupedRadius: 8)
            .path(for: rect, side: .trailing, tail: true, groupedAbove: false, groupedBelow: false, tailReach: 0)
    }

    /// Springs into the bubble at `target` (this view's coordinates), then calls `completion`.
    func morph(
        to target: CGRect,
        textOrigin: CGPoint,
        groupedAbove: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        // The newest user bubble is always the last of its group, so it has the tail; a
        // bubble directly above from the user gives it the small grouped top corner.
        let endPath = AcpmuxBubblePath()
            .path(for: target, side: .trailing, tail: true, groupedAbove: groupedAbove, groupedBelow: false)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        add(spring("path", from: startPath(startRect), to: endPath), to: shape)
        let fillFade = CABasicAnimation(keyPath: "opacity")
        fillFade.fromValue = 0
        fillFade.toValue = 1
        fillFade.duration = 0.12
        add(fillFade, to: shape)
        let endOrigin = CGPoint(x: target.minX + textOrigin.x, y: target.minY + textOrigin.y)
        for (label, from, to) in [(sourceLabel, 1.0, 0.0), (finalLabel, 0.0, 1.0)] {
            guard let labelLayer = label.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = 0.16
            add(fade, to: labelLayer)
            let start = labelLayer.position
            let delta = CGPoint(x: endOrigin.x - startRect.minX, y: endOrigin.y - startRect.minY)
            add(spring("position", from: NSValue(point: start),
                       to: NSValue(point: CGPoint(x: start.x + delta.x, y: start.y + delta.y))), to: labelLayer)
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
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: (animation as? CAPropertyAnimation)?.keyPath)
    }
}
