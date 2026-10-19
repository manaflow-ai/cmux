import CmuxNextDesign
import CoreText
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
    /// The keystroke caption: a pill under and right of the arrow with what
    /// the agent types (``AgentKeystrokeCaption``).
    let caption = CALayer()
    let captionText = CATextLayer()
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
        caption.backgroundColor = CGColor(gray: 0.08, alpha: 0.86)
        caption.borderColor = color
        caption.borderWidth = 1.5
        caption.cornerRadius = Self.captionHeight / 2
        caption.anchorPoint = .zero
        caption.opacity = 0
        captionText.font = Self.captionFont
        captionText.fontSize = Self.captionFontSize
        captionText.foregroundColor = CGColor(gray: 1, alpha: 1)
        captionText.alignmentMode = .center
        captionText.truncationMode = .start
        caption.addSublayer(captionText)
        root.addSublayer(ripple)
        root.addSublayer(arrow)
        root.addSublayer(indicator)
        root.addSublayer(caption)
    }

    static let captionFontSize: CGFloat = 12
    static let captionHeight: CGFloat = 22
    static let captionFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, captionFontSize, nil)
        ?? CTFontCreateWithName("Helvetica-Bold" as CFString, captionFontSize, nil)
    /// Where the caption's top-left corner sits from the arrow tip: right of
    /// the arrow's tail, so it never covers the point the agent acts on.
    static let captionOffset = CGPoint(x: 16, y: 20)
    /// How long the caption stays after the last keystroke.
    static let captionHideDelay: CFTimeInterval = 1.6
    static let captionHideKey = "agentCursor.captionHide"

    /// The width `text` needs in the caption font.
    static func captionWidth(_ text: String) -> CGFloat {
        let attributed = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: captionFont] as CFDictionary)
        guard let attributed else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Shows `text` in the caption at once, then fades it out
    /// ``captionHideDelay`` after this keystroke unless another comes.
    func showCaption(_ text: String, scale: CGFloat) {
        let padding: CGFloat = 9
        let width = Self.captionWidth(text) + padding * 2
        caption.frame = CGRect(origin: Self.captionOffset, size: CGSize(width: width, height: Self.captionHeight))
        let lineHeight = ceil(Self.captionFontSize * 1.3)
        captionText.frame = CGRect(x: padding, y: (Self.captionHeight - lineHeight) / 2,
                                   width: width - padding * 2, height: lineHeight)
        captionText.contentsScale = scale
        captionText.string = text
        caption.opacity = 1
        caption.removeAnimation(forKey: Self.captionHideKey)
        caption.add(Motion.scheduledFade(.cursorHide, "opacity", from: 1, to: 0, after: Self.captionHideDelay, on: caption),
                    forKey: Self.captionHideKey)
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
            caption.isHidden = showsIndicator
        }
    }

    /// Idle hide (agent-cursor.md): one opacity animation that begins `delay`
    /// seconds from now and holds the cursor hidden; every agent action arms
    /// it again, which shows the cursor at once. No timer.
    func armIdleHide(after delay: CFTimeInterval) {
        root.add(Motion.scheduledFade(.cursorHide, "opacity", from: 1, to: 0, after: delay, on: root), forKey: Self.idleHideKey)
    }

    static let idleHideKey = "agentCursor.idleHide"

    /// Click feedback: the ripple grows and fades (`MotionFade.clickPulse`,
    /// 0.25 s at the fast speed, cmux-cua timing). Reduce Motion keeps only
    /// the fade, at the ring's full size; speed "off" shows no ripple.
    func pulse() {
        if Motion.set(ripple, "transform.scale", to: 1.6, movementFade: .clickPulse, from: 0.4) == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ripple.transform = CATransform3DMakeScale(1.6, 1.6, 1)
            CATransaction.commit()
        }
        Motion.set(ripple, "opacity", to: 0, fade: .clickPulse, from: 0.9)
    }
}
