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
    // Cells set every property on each configure; only real changes redraw.
    var side: BubbleShape.Side = .trailing { didSet { if side != oldValue { setNeedsLayout() } } }
    var hasTail = true { didSet { if hasTail != oldValue { setNeedsLayout() } } }
    var fillColor: UIColor = ConversationTheme.outgoingBubble { didSet { if fillColor != oldValue { updateColors() } } }
    var strokeColor: UIColor? { didSet { if strokeColor != oldValue { updateColors() } } }
    /// Fill with Messages' screen-anchored gradient instead of `fillColor`:
    /// the shade depends on where the bubble sits in the window, so call
    /// `updateScreenGradient()` when it moves without relayout (scrolling).
    var screenGradient: ConversationTheme.ScreenGradient? { didSet { if screenGradient != oldValue { updateColors() } } }
    /// The bubble-shaped host of the gradient (masked by the outline).
    private var gradientLayer: CALayer?
    /// The whole screen's gradient, three windows tall with the window in
    /// the middle third, so the bubble shows the slice it sits over. Its
    /// colors never change while scrolling; only its position follows the
    /// bubble's place in the window (see `updateScreenGradient`).
    private let gradientFill = CAGradientLayer()
    private var gradientFillKey: (height: CGFloat, width: CGFloat, dark: Bool, contrast: Bool)?
    /// Over a conversation background, this bubble (an incoming one) turns
    /// into a translucent material, as ChatKit's `forcesMaterialBackground`
    /// balloons do; Reduce Transparency keeps the opaque fill.
    var adaptsToBackdrop = false { didSet { if adaptsToBackdrop != oldValue { updateColors() } } }
    private var materialView: UIVisualEffectView?
    private let materialMask = BubbleMaskView()

    /// Send Later outline: a dashed stroke inset so it stays inside the shape.
    var isDashed = false {
        didSet {
            guard isDashed != oldValue else { return }
            shapeLayer.lineDashPattern = isDashed ? SendLaterStyle.dashPattern : nil
            shapeLayer.lineWidth = isDashed ? SendLaterStyle.outlineWidth : 1
            setNeedsLayout()
        }
    }

    /// Fades the fill in from `color` (a scheduled bubble turning sent).
    func animateFill(from color: UIColor, duration: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "fillColor")
        fade.fromValue = color.resolvedColor(with: traitCollection).cgColor
        fade.toValue = shapeLayer.fillColor
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shapeLayer.add(fade, forKey: "sendLaterFill")
    }

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
        let inset = isDashed ? SendLaterStyle.outlineWidth / 2 : 0
        let path = BubbleShape.path(in: bounds.insetBy(dx: inset, dy: inset), side: side, tail: hasTail).cgPath
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
            // The tail drops below the bounds; the gradient covers it too.
            // Pinned at its top-left corner, the gradient's size follows the
            // outline's animation (a send flight's collapse) instead of
            // jumping to the final size and cutting the bubble off.
            let oldSize = gradientLayer.bounds.size
            let size = gradientBounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradientLayer.anchorPoint = .zero
            gradientLayer.position = gradientBounds.origin
            gradientLayer.bounds = CGRect(origin: .zero, size: size)
            mask.frame = CGRect(origin: .zero, size: size)
            CATransaction.commit()
            if let animation = shapeLayer.animation(forKey: "path") as? CABasicAnimation {
                mask.add(animation.copy() as! CABasicAnimation, forKey: "path")
                if oldSize != size {
                    let resize = CABasicAnimation(keyPath: "bounds.size")
                    resize.duration = animation.duration
                    resize.timingFunction = animation.timingFunction
                    resize.isAdditive = true
                    resize.fromValue = NSValue(cgSize: CGSize(width: oldSize.width - size.width, height: oldSize.height - size.height))
                    resize.toValue = NSValue(cgSize: .zero)
                    gradientLayer.add(resize, forKey: "bounds.size")
                }
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

    /// The bounds plus the tail's drop below them.
    private var gradientBounds: CGRect {
        var rect = bounds
        rect.size.height += ConversationTheme.tailDrop
        return rect
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScreenGradient()
    }

    /// Keeps the screen gradient fixed to the window as the bubble moves:
    /// one position change per call; the colors are set only when the
    /// window size or appearance changes.
    func updateScreenGradient() {
        guard gradientLayer != nil, let screenGradient, let window, window.bounds.height > 0 else { return }
        let height = window.bounds.height
        let width = max(window.bounds.width, bounds.width)
        let traits = traitCollection
        let key = (height: height, width: width, dark: traits.userInterfaceStyle == .dark, contrast: traits.accessibilityContrast == .high)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if gradientFillKey.map({ $0 != key }) ?? true {
            gradientFillKey = key
            let sample = screenGradient.windowSamples(traits: traits)
            gradientFill.colors = sample.colors
            gradientFill.locations = sample.locations.map { NSNumber(value: Double($0)) }
            gradientFill.anchorPoint = .zero
            gradientFill.bounds = CGRect(x: 0, y: 0, width: width, height: 3 * height)
        }
        let top = convert(CGPoint.zero, to: window).y
        let position = CGPoint(x: 0, y: -top - height)
        if gradientFill.position != position { gradientFill.position = position }
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
            let gradient = CALayer()
            gradient.masksToBounds = true
            gradient.addSublayer(gradientFill)
            let mask = CAShapeLayer()
            gradient.mask = mask
            gradient.anchorPoint = .zero
            gradient.frame = gradientBounds
            mask.frame = CGRect(origin: .zero, size: gradientBounds.size)
            mask.path = shapeLayer.path
            layer.insertSublayer(gradient, at: 0)
            gradientLayer = gradient
        }
        gradientLayer?.isHidden = screenGradient == nil
        gradientFillKey = nil
        updateScreenGradient()
    }
}

/// A view whose layer is a shape, used as a material's bubble-shaped mask.
final class BubbleMaskView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shape: CAShapeLayer { layer as! CAShapeLayer }
}
#endif
