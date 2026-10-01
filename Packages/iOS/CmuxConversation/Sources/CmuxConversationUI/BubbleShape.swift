#if canImport(UIKit)
import UIKit

/// The Messages bubble outline. The tail sits at the bottom corner on the
/// sender's side and extends `ConversationTheme.tailWidth` past the body.
enum BubbleShape {
    enum Side {
        case leading
        case trailing
    }

    /// `rect` includes the tail area on `side` whether or not a tail is drawn,
    /// so tailed and tailless bubbles in a group share one body edge.
    static func path(in rect: CGRect, side: Side, tail: Bool, radius: CGFloat = ConversationTheme.bubbleCornerRadius) -> UIBezierPath {
        let tailWidth = ConversationTheme.tailWidth
        var body = rect
        body.size.width -= tailWidth
        if side == .leading { body.origin.x += tailWidth }
        let r = min(radius, body.height / 2, body.width / 2)
        guard tail else {
            return UIBezierPath(roundedRect: body, cornerRadius: r)
        }
        let path = trailingTailPath(width: body.width, height: body.height, radius: r, tailWidth: tailWidth)
        var transform = CGAffineTransform.identity
        if side == .leading {
            transform = CGAffineTransform(translationX: rect.maxX, y: rect.minY).scaledBy(x: -1, y: 1)
        } else {
            transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        }
        path.apply(transform)
        return path
    }

    /// Body spans x in [0, width] and y in [0, height]. iOS 26's tail leaves
    /// the bottom edge near the corner, curls out past the right edge, and
    /// drops `tailDrop` below the body to a softly rounded tip.
    private static func trailingTailPath(width w: CGFloat, height h: CGFloat, radius r: CGFloat, tailWidth t: CGFloat) -> UIBezierPath {
        let k: CGFloat = 0.4477 // control-point factor approximating a quarter circle
        let d = ConversationTheme.tailDrop
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addCurve(to: CGPoint(x: w, y: r), controlPoint1: CGPoint(x: w - r * k, y: 0), controlPoint2: CGPoint(x: w, y: r * k))
        let shoulder = max(r, h - r * 0.55)
        p.addLine(to: CGPoint(x: w, y: shoulder))
        // Outer edge of the tail: a concave sweep from the side down to the tip.
        let tip = CGPoint(x: w + t * 0.95, y: h + d)
        p.addCurve(to: tip, controlPoint1: CGPoint(x: w, y: h - r * 0.05), controlPoint2: CGPoint(x: w - 1.5, y: h + d * 0.55))
        // Rounded tip, then the inner edge back into the bottom of the body.
        p.addCurve(to: CGPoint(x: w - 4, y: h + d - 1.2), controlPoint1: CGPoint(x: w + t * 0.95 + 0.6, y: h + d + 0.9), controlPoint2: CGPoint(x: w - 2.2, y: h + d - 0.2))
        p.addCurve(to: CGPoint(x: w - r * 1.05, y: h), controlPoint1: CGPoint(x: w - 7, y: h + d * 0.55), controlPoint2: CGPoint(x: w - r * 0.65, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h - r), controlPoint1: CGPoint(x: r * k, y: h), controlPoint2: CGPoint(x: 0, y: h - r * k))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addCurve(to: CGPoint(x: r, y: 0), controlPoint1: CGPoint(x: 0, y: r * k), controlPoint2: CGPoint(x: r * k, y: 0))
        p.close()
        return p
    }
}

/// A filled bubble outline that redraws whenever its bounds change.
final class BubbleBackgroundView: UIView {
    var side: BubbleShape.Side = .trailing { didSet { setNeedsLayout() } }
    var hasTail = true { didSet { setNeedsLayout() } }
    var fillColor: UIColor = ConversationTheme.outgoingBubble { didSet { updateColors() } }
    var strokeColor: UIColor? { didSet { updateColors() } }

    override class var layerClass: AnyClass { CAShapeLayer.self }
    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shapeLayer.lineWidth = 1
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = BubbleShape.path(in: bounds, side: side, tail: hasTail).cgPath
        // Animate the outline with the bounds when the change is animated.
        if let animation = layer.action(forKey: "bounds") as? CABasicAnimation ?? layer.animation(forKey: "bounds.size") as? CABasicAnimation {
            let pathAnimation = CABasicAnimation(keyPath: "path")
            pathAnimation.duration = animation.duration
            pathAnimation.timingFunction = animation.timingFunction
            pathAnimation.fromValue = shapeLayer.path
            shapeLayer.add(pathAnimation, forKey: "path")
        }
        shapeLayer.path = path
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        shapeLayer.fillColor = fillColor.resolvedColor(with: traitCollection).cgColor
        shapeLayer.strokeColor = strokeColor?.resolvedColor(with: traitCollection).cgColor
    }
}
#endif
