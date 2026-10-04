public import QuartzCore

/// One agent's cursor: arrow, click ripple and the hidden-target indicator,
/// all CAShapeLayers under `root`, whose `position` is the arrow tip. A
/// wrapper, not a CALayer subclass, so CoreAnimation's presentation copies
/// never run app code.
public final class AgentCursorLayer {
    /// Arrow outline with the tip at the origin (y-down points), the shape of
    /// the cmux-cua cursor at rest.
    static let arrowPath: CGPath = {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.addLine(to: CGPoint(x: 4.5, y: 12.8))
        path.addLine(to: CGPoint(x: 7.6, y: 19.6))
        path.addLine(to: CGPoint(x: 10.4, y: 18.4))
        path.addLine(to: CGPoint(x: 7.4, y: 11.8))
        path.addLine(to: CGPoint(x: 13.2, y: 11.8))
        path.closeSubpath()
        return path
    }()

    public let root = CALayer()
    let arrow = CAShapeLayer()
    let ripple = CAShapeLayer()
    let indicator = CAShapeLayer()
    private let fill: CGColor

    public init(color: CGColor) {
        fill = color
        root.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        root.anchorPoint = .zero
        arrow.path = Self.arrowPath
        arrow.fillColor = color
        arrow.strokeColor = CGColor(gray: 0, alpha: 0.55)
        arrow.lineWidth = 1
        ripple.path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        ripple.fillColor = nil
        ripple.strokeColor = color
        ripple.lineWidth = 2
        ripple.opacity = 0
        indicator.path = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
        indicator.fillColor = color
        indicator.isHidden = true
        root.addSublayer(ripple)
        root.addSublayer(arrow)
        root.addSublayer(indicator)
    }

    /// The person paused or took over: an outline, no fill.
    public var isPaused = false {
        didSet { arrow.fillColor = isPaused ? nil : fill }
    }

    /// The target is hidden: a dot at its tab chip or column edge, no arrow.
    public var showsIndicator = false {
        didSet {
            indicator.isHidden = !showsIndicator
            arrow.isHidden = showsIndicator
        }
    }

    /// Click feedback: the ripple grows and fades in 0.25 s (cmux-cua timing).
    func pulse() {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.25
        ripple.add(group, forKey: "agentCursor.pulse")
    }
}
