import CmuxNextDesign
import CoreText
public import QuartzCore

/// One agent's cursor: arrow, name tag, click ripple and the hidden-target indicator,
/// all CAShapeLayers under `root`, whose `position` is the arrow tip. A
/// wrapper, not a CALayer subclass, so CoreAnimation's presentation copies
/// never run app code.
public final class AgentCursorLayer {
    /// Pointer outline with the tip at the origin (y-down points): the
    /// minimal triangle (a dart with a shallow notch) with every corner
    /// rounded (cursor gallery T1, user 2026-10-20: "I like the minimal
    /// triangle. It just needs to be more friendly").
    static let arrowPath: CGPath = {
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 0, y: 0), 2.2), (CGPoint(x: 16, y: 7), 2.6),
            (CGPoint(x: 10.5, y: 10.5), 3), (CGPoint(x: 7, y: 16), 2.6),
        ]
        let path = roundedPolygon(corners)
        let box = path.boundingBoxOfPath
        var place = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        return path.copy(using: &place) ?? path
    }()

    /// Every agent's pointer fill: a mid gray that reads on light and dark
    /// pages (user, 2026-10-20: "the cursor color for all the browser view
    /// stuff needs to be gray").
    public static let gray = CGColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1)
    /// The pointer's rim, so the gray reads over any page.
    static let rim = CGColor(gray: 1, alpha: 1)
    /// The name tag and caption tint, gray Liquid Glass (pill gallery P1, user
    /// 2026-10-20): 18% system gray over the real blur the overlay panel's
    /// behind-window glass draws under each tag shape (``glassRoot``).
    static let glass = CGColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 0.18)
    static let glassText = CGColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 0.88)
    /// The glass's specular rim: a light inner edge.
    static let glassRim = CGColor(gray: 1, alpha: 0.55)
    /// The glass's top highlight, fading out before the middle.
    static let glassSheen: [CGColor] = [CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0)]

    public let root = CALayer()
    /// The arrow and ripple, turned with the travel heading; the name tag
    /// and caption sit on `root` and stay level.
    public let heading = CALayer()
    let arrow = CAShapeLayer()
    let ripple = CAShapeLayer()
    let indicator = CAShapeLayer()
    /// The keystroke caption: a pill under and right of the arrow with what
    /// the agent types (``AgentKeystrokeCaption``).
    let caption = CALayer()
    let captionText = CATextLayer()
    /// The agent's name in a light glass pill against the pointer tip, with a
    /// dot in the pointer color
    /// (``AgentCursorSessionLabel``), so the person sees whose cursor it is.
    let nameTag = CALayer()
    let nameText = CATextLayer()
    let nameDot = CAShapeLayer()
    /// The glass's specular highlight across the tag's top half.
    let nameSheen = CAGradientLayer()
    /// The cursor's blur shapes, in the window's glass mask layer
    /// (`WindowOverlayHost.agentCursorGlassLayer`): moved, faded, hidden and
    /// removed with ``root`` (``roots``), so the blur stays under the tag.
    public let glassRoot = CALayer()
    /// The tag's blur well: an opaque capsule in the tag's frame.
    let glassTag = CALayer()
    /// The caption's blur well.
    let glassCaption = CALayer()
    /// The layers that carry the cursor's position, visibility and idle fade.
    var roots: [CALayer] { [root, glassRoot] }
    private let fill: CGColor
    /// The cursor has a name tag to show.
    let hasName: Bool

    /// - Parameters:
    ///   - color: The session's fill.
    ///   - name: The name tag text; nil or empty shows no tag.
    ///   - scale: The text's backing scale.
    public init(color: CGColor, name: String? = nil, scale: CGFloat = 2) {
        fill = color
        hasName = !(name ?? "").isEmpty
        root.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        root.anchorPoint = .zero
        heading.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        heading.anchorPoint = .zero
        arrow.path = Self.arrowPath
        arrow.fillColor = color
        arrow.strokeColor = Self.rim
        arrow.lineWidth = 1.5
        arrow.lineJoin = .round
        arrow.shadowColor = CGColor(gray: 0, alpha: 1)
        arrow.shadowOpacity = 0.3
        arrow.shadowRadius = 2
        arrow.shadowOffset = .zero
        arrow.shadowPath = Self.arrowPath
        ripple.path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        ripple.fillColor = color.copy(alpha: 0.3)
        ripple.strokeColor = color.copy(alpha: 0.6)
        ripple.lineWidth = 1
        ripple.opacity = 0
        indicator.path = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
        indicator.fillColor = color
        indicator.strokeColor = Self.rim
        indicator.lineWidth = 1.5
        indicator.isHidden = true
        caption.backgroundColor = Self.glass
        caption.borderColor = Self.glassRim
        caption.borderWidth = 0.5
        caption.cornerCurve = .continuous
        caption.shadowColor = CGColor(gray: 0, alpha: 1)
        caption.shadowOpacity = 0.16
        caption.shadowRadius = 5
        caption.shadowOffset = .zero
        caption.cornerRadius = Self.captionHeight / 2
        caption.anchorPoint = .zero
        caption.opacity = 0
        captionText.font = Self.captionFont
        captionText.fontSize = Self.captionFontSize
        captionText.foregroundColor = Self.glassText
        captionText.alignmentMode = .center
        captionText.truncationMode = .start
        caption.addSublayer(captionText)
        nameTag.backgroundColor = Self.glass
        nameTag.borderColor = Self.glassRim
        nameTag.borderWidth = 0.75
        nameTag.cornerCurve = .continuous
        nameTag.masksToBounds = false
        nameTag.shadowColor = CGColor(gray: 0, alpha: 1)
        nameTag.shadowOpacity = 0.18
        nameTag.shadowRadius = 4
        nameTag.shadowOffset = CGSize(width: 0, height: 1.5)
        nameSheen.colors = Self.glassSheen
        nameSheen.startPoint = CGPoint(x: 0.5, y: 0)
        nameSheen.endPoint = CGPoint(x: 0.5, y: 1)
        nameSheen.cornerCurve = .continuous
        nameSheen.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        nameTag.addSublayer(nameSheen)
        nameDot.fillColor = Self.gray
        nameTag.addSublayer(nameDot)
        nameTag.cornerRadius = Self.tagHeight / 2
        nameTag.anchorPoint = .zero
        nameText.font = Self.captionFont
        nameText.fontSize = Self.tagFontSize
        nameText.foregroundColor = Self.glassText
        nameText.alignmentMode = .center
        nameText.truncationMode = .end
        nameText.contentsScale = scale
        nameTag.addSublayer(nameText)
        if let name, !name.isEmpty {
            let padding: CGFloat = 9, dot: CGFloat = 6, gap: CGFloat = 5
            let lead = padding + dot + gap
            let width = Self.captionWidth(name, size: Self.tagFontSize) + lead + padding
            nameTag.frame = CGRect(origin: Self.tagOffset, size: CGSize(width: width, height: Self.tagHeight))
            nameSheen.frame = CGRect(x: 0, y: 0, width: width, height: Self.tagHeight * 0.55)
            nameSheen.cornerRadius = Self.tagHeight / 2
            nameDot.path = CGPath(ellipseIn: CGRect(x: padding, y: (Self.tagHeight - dot) / 2, width: dot, height: dot), transform: nil)
            let lineHeight = ceil(Self.tagFontSize * 1.3)
            nameText.frame = CGRect(x: lead, y: (Self.tagHeight - lineHeight) / 2, width: width - lead - padding, height: lineHeight)
            nameText.string = name
        } else {
            nameTag.isHidden = true
        }
        glassRoot.bounds = root.bounds
        glassRoot.anchorPoint = .zero
        for well in [glassTag, glassCaption] {
            well.backgroundColor = CGColor(gray: 0, alpha: 1)
            well.cornerCurve = .continuous
            well.anchorPoint = .zero
            glassRoot.addSublayer(well)
        }
        glassTag.frame = nameTag.frame
        glassTag.cornerRadius = nameTag.cornerRadius
        glassTag.isHidden = nameTag.isHidden
        glassCaption.cornerRadius = Self.captionHeight / 2
        glassCaption.opacity = 0
        heading.addSublayer(ripple)
        heading.addSublayer(arrow)
        root.addSublayer(heading)
        root.addSublayer(indicator)
        root.addSublayer(nameTag)
        root.addSublayer(caption)
    }

    static let tagFontSize: CGFloat = 11
    static let tagHeight: CGFloat = 22
    /// The name tag's top-left corner from the arrow tip: right of the
    /// arrow's tail, never over the point the agent acts on.
    static let tagOffset = CGPoint(x: 11, y: 13)

    static let captionFontSize: CGFloat = 12
    static let captionHeight: CGFloat = 22
    /// The caption's font, the bold system font (made per use: a CTFont is not Sendable).
    static var captionFont: CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, captionFontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, captionFontSize, nil)
    }
    /// Where the caption's top-left corner sits from the arrow tip: right of
    /// the arrow's tail, so it never covers the point the agent acts on.
    static let captionOffset = CGPoint(x: 16, y: 20)

    /// Where the caption goes: under the name tag when there is one.
    var captionOrigin: CGPoint {
        !hasName ? Self.captionOffset : CGPoint(x: Self.tagOffset.x, y: nameTag.frame.maxY + 4)
    }
    /// How long the caption stays after the last keystroke.
    static let captionHideDelay: CFTimeInterval = 1.6
    static let captionHideKey = "agentCursor.captionHide"

    /// The width `text` needs in the caption font.
    static func captionWidth(_ text: String, size: CGFloat = captionFontSize) -> CGFloat {
        let font = size == captionFontSize ? captionFont : CTFontCreateCopyWithAttributes(captionFont, size, nil, nil)
        let attributes = [kCTFontAttributeName as String: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Shows `text` in the caption at once, then fades it out
    /// ``captionHideDelay`` after this keystroke unless another comes.
    func showCaption(_ text: String, scale: CGFloat) {
        let padding: CGFloat = 9
        let width = Self.captionWidth(text) + padding * 2
        caption.frame = CGRect(origin: captionOrigin, size: CGSize(width: width, height: Self.captionHeight))
        let lineHeight = ceil(Self.captionFontSize * 1.3)
        captionText.frame = CGRect(x: padding, y: (Self.captionHeight - lineHeight) / 2,
                                   width: width - padding * 2, height: lineHeight)
        captionText.contentsScale = scale
        captionText.string = text
        glassCaption.frame = caption.frame
        for layer in [caption, glassCaption] {
            layer.opacity = 1
            layer.removeAnimation(forKey: Self.captionHideKey)
            layer.add(Motion.scheduledFade(.cursorHide, "opacity", from: 1, to: 0, after: Self.captionHideDelay, on: layer),
                      forKey: Self.captionHideKey)
        }
    }

    /// The name tag's text, nil without a tag (diagnostics: `debug.agent_cursor`).
    public var tagText: String? { hasName ? nameText.string as? String : nil }
    /// The keystroke caption's last text (diagnostics).
    public var captionString: String? { captionText.string as? String }

    /// The person paused or took over: an outline, no fill.
    public var isPaused = false {
        didSet {
            arrow.fillColor = isPaused ? nil : fill
            arrow.strokeColor = isPaused ? fill : Self.rim
        }
    }

    /// The target is hidden: a dot at its tab chip or column edge, no arrow.
    public var showsIndicator = false {
        didSet {
            indicator.isHidden = !showsIndicator
            arrow.isHidden = showsIndicator
            caption.isHidden = showsIndicator
            glassCaption.isHidden = showsIndicator
            nameTag.isHidden = showsIndicator || !hasName
            glassTag.isHidden = nameTag.isHidden
        }
    }

    /// Idle hide (agent-cursor.md): one opacity animation that begins `delay`
    /// seconds from now and holds the cursor hidden; every agent action arms
    /// it again, which shows the cursor at once. No timer.
    func armIdleHide(after delay: CFTimeInterval) {
        for layer in roots {
            layer.add(Motion.scheduledFade(.cursorHide, "opacity", from: 1, to: 0, after: delay, on: layer), forKey: Self.idleHideKey)
        }
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

/// A closed polygon with each corner rounded by a circular arc; a radius
/// shrinks where its edges are too short to hold it, so tight corners stay smooth.
private func roundedPolygon(_ corners: [(CGPoint, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    let count = corners.count
    let last = corners[count - 1].0, first = corners[0].0
    path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
    for index in 0..<count {
        let (point, radius) = corners[index]
        let previous = corners[(index + count - 1) % count].0
        let next = corners[(index + 1) % count].0
        let toPrevious = hypot(previous.x - point.x, previous.y - point.y)
        let toNext = hypot(next.x - point.x, next.y - point.y)
        let cosine = ((previous.x - point.x) * (next.x - point.x) + (previous.y - point.y) * (next.y - point.y)) / (toPrevious * toNext)
        let half = acos(max(-1, min(1, cosine))) / 2
        let reach = min(radius / tan(half), 0.45 * toPrevious, 0.45 * toNext)
        path.addArc(tangent1End: point, tangent2End: next, radius: reach * tan(half))
    }
    path.closeSubpath()
    return path
}
