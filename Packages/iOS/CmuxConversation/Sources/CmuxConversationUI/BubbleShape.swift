#if canImport(UIKit)
import CmuxConversationGeometry
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
        let shared = ConversationBubbleGeometry.path(
            in: rect,
            side: side == .leading ? .leading : .trailing,
            tail: true,
            radius: r,
            tailWidth: tailWidth,
            tailDrop: ConversationTheme.tailDrop
        )
        return UIBezierPath(cgPath: shared)
    }
}

/// A filled bubble outline that redraws whenever its bounds change.
final class BubbleBackgroundView: UIView {
    var side: BubbleShape.Side = .trailing { didSet { setNeedsLayout() } }
    var hasTail = true { didSet { setNeedsLayout() } }
    var fillColor: UIColor = ConversationTheme.outgoingBubble { didSet { updateColors() } }
    var strokeColor: UIColor? { didSet { updateColors() } }
    /// Fill with Messages' screen-anchored gradient instead of `fillColor`:
    /// the shade depends on where the bubble sits in the window, so call
    /// `updateScreenGradient()` when it moves without relayout (scrolling).
    var screenGradient: ConversationTheme.ScreenGradient? { didSet { updateColors() } }
    private var gradientLayer: CAGradientLayer?
    /// Over a conversation background, this bubble (an incoming one) turns
    /// into a translucent material, as ChatKit's `forcesMaterialBackground`
    /// balloons do; Reduce Transparency keeps the opaque fill.
    var adaptsToBackdrop = false { didSet { if adaptsToBackdrop != oldValue { updateColors() } } }
    private var materialView: UIVisualEffectView?
    private let materialMask = BubbleMaskView()

    override class var layerClass: AnyClass { CAShapeLayer.self }
    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shapeLayer.lineWidth = 1
        registerForTraitChanges([ConversationBackdropTrait.self]) { (self: Self, _: UITraitCollection) in
            self.updateColors()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reduceTransparencyChanged), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        updateColors()
    }

    @objc private func reduceTransparencyChanged() {
        updateColors()
    }

    /// Material instead of a fill: over a background, unless Reduce Transparency is on.
    private var usesMaterial: Bool {
        adaptsToBackdrop && screenGradient == nil && traitCollection.isOverConversationBackdrop && !UIAccessibility.isReduceTransparencyEnabled
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
        if let gradientLayer, let mask = gradientLayer.mask as? CAShapeLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradientLayer.frame = bounds
            mask.frame = bounds
            CATransaction.commit()
            if let animation = shapeLayer.animation(forKey: "path")?.copy() as? CABasicAnimation {
                mask.add(animation, forKey: "path")
            }
            mask.path = path
        }
        if let materialView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            materialView.frame = bounds
            materialMask.frame = bounds
            CATransaction.commit()
            if let animation = shapeLayer.animation(forKey: "path")?.copy() as? CABasicAnimation {
                materialMask.shape.add(animation, forKey: "path")
            }
            materialMask.shape.path = path
        }
        updateScreenGradient()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScreenGradient()
    }

    /// Re-samples the gradient for the bubble's current place in the window.
    func updateScreenGradient() {
        guard let gradientLayer, let screenGradient, let window, window.bounds.height > 0 else { return }
        let frame = convert(bounds, to: window)
        let top = frame.minY / window.bounds.height
        let bottom = frame.maxY / window.bounds.height
        let sample = screenGradient.samples(from: top, to: bottom, traits: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = sample.colors
        gradientLayer.locations = sample.locations.map { NSNumber(value: Double($0)) }
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        let material = usesMaterial
        if material, materialView == nil {
            let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            effect.isUserInteractionEnabled = false
            effect.frame = bounds
            materialMask.frame = bounds
            materialMask.shape.path = shapeLayer.path
            effect.mask = materialMask
            insertSubview(effect, at: 0)
            materialView = effect
        }
        materialView?.isHidden = !material
        // The material carries a light wash of the bubble's own gray so it
        // still reads as an incoming bubble over busy photos.
        materialView?.contentView.backgroundColor = material ? fillColor.resolvedColor(with: traitCollection).withAlphaComponent(0.32) : nil
        shapeLayer.fillColor = screenGradient == nil && !material ? fillColor.resolvedColor(with: traitCollection).cgColor : UIColor.clear.cgColor
        shapeLayer.strokeColor = strokeColor?.resolvedColor(with: traitCollection).cgColor
        if screenGradient != nil, gradientLayer == nil {
            let gradient = CAGradientLayer()
            let mask = CAShapeLayer()
            gradient.mask = mask
            gradient.frame = bounds
            mask.frame = bounds
            mask.path = shapeLayer.path
            layer.insertSublayer(gradient, at: 0)
            gradientLayer = gradient
        }
        gradientLayer?.isHidden = screenGradient == nil
        updateScreenGradient()
    }
}

/// A view whose layer is a shape, used as a material's bubble-shaped mask.
final class BubbleMaskView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shape: CAShapeLayer { layer as! CAShapeLayer }
}
#endif
