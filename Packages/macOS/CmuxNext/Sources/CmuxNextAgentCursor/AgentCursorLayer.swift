import CmuxNextDesign
import CoreText
import Foundation
public import QuartzCore

/// One agent's cursor: arrow, name tag, click ripple and the hidden-target indicator,
/// all CAShapeLayers under `root`, whose `position` is the arrow tip. A
/// wrapper, not a CALayer subclass, so CoreAnimation's presentation copies
/// never run app code.
public final class AgentCursorLayer {
    /// Pointer outline with the tip at the origin (y-down points): the
    /// system pointer's posture (a vertical left edge, the body leaning 22°
    /// right, a 44° tip) without its stick tail, every corner rounded and a
    /// shallow notch for a back (shape gallery S1, user 2026-10-20: "Think
    /// from first principles about how to make the cursor shape even more
    /// friendly and perfect"). Vertices sit on the 0.25 pt grid; the
    /// rounding trims the acute corners, so it draws about 11.5 × 15.3 pt.
    static let arrowPath: CGPath = {
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 0, y: 0), 1.3), (CGPoint(x: 14.5, y: 15), 1.6),
            (CGPoint(x: 4.5, y: 11.25), 2), (CGPoint(x: 0, y: 21), 1.6),
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
    /// The glass dart's tint over the blur of the page under it (user,
    /// 2026-10-20: "glassier, but clearly visible on every kind of surface").
    static let dartTint = gray.copy(alpha: 0.55) ?? gray
    /// The dark hairline outside the white rim: it draws the dart's edge on
    /// white pages, where the white rim does not show; the rim draws it on
    /// dark pages and terminals. A soft shadow lifts it off busy photos.
    static let outline = CGColor(gray: 0, alpha: 0.45)
    /// The dart's specular highlight, top-left to the middle.
    static let dartSheen: [CGColor] = [CGColor(gray: 1, alpha: 0.45), CGColor(gray: 1, alpha: 0)]
    /// The name tag and caption glass: the shared ``FloatingGlassStyle/agentTag`` (Chief via
    /// a286, 2026-10-20: one Liquid Glass style, never a fork). Always its light look: the tag
    /// floats over web pages of any color on a light behind-window blur (the overlay carrier
    /// pins `.aqua`), under dark label text.
    static let tagStyle = FloatingGlassStyle.agentTag
    static let glassText = CGColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 0.88)
    /// How much denser the veil is while the pointer is on the tag (it is a link).
    static let hoverVeilBoost: Double = 0.15

    public let root = CALayer()
    /// The arrow and ripple, turned with the travel heading; the name tag
    /// and caption sit on `root` and stay level.
    public let heading = CALayer()
    let arrow = CAShapeLayer()
    /// The dark hairline and shadow under the dart's white rim.
    let arrowOutline = CAShapeLayer()
    /// The dart's specular highlight, masked to its shape.
    let arrowSheen = CAGradientLayer()
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
    /// The shared glass's soft top-lit rim around the tag, and around the caption.
    let nameRim = CAGradientLayer()
    let captionRim = CAGradientLayer()
    /// The cursor's blur shapes, in the window's glass mask layer
    /// (`WindowOverlayHost.agentCursorGlassLayer`): moved, faded, hidden and
    /// removed with ``root`` (``roots``), so the blur stays under the tag.
    public let glassRoot = CALayer()
    /// The tag's blur well: an opaque capsule in the tag's frame.
    let glassTag = CALayer()
    /// The caption's blur well.
    let glassCaption = CALayer()
    /// Turns the dart's blur well with ``heading``.
    public let glassHeading = CALayer()
    /// The dart's blur well: its shape, opaque.
    let glassArrow = CAShapeLayer()
    /// The layers that turn with the travel heading.
    var headings: [CALayer] { [heading, glassHeading] }
    /// How long the last glide played, 0 when it moved at once (Reduce
    /// Motion, animations off); nil before any glide (diagnostics and tests).
    public internal(set) var lastGlideDuration: CFTimeInterval?
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
        arrowOutline.path = Self.arrowPath
        arrowOutline.fillColor = nil
        arrowOutline.strokeColor = Self.outline
        arrowOutline.lineWidth = 2.9
        arrowOutline.lineJoin = .round
        arrowOutline.shadowColor = CGColor(gray: 0, alpha: 1)
        arrowOutline.shadowOpacity = 0.28
        arrowOutline.shadowRadius = 2.5
        arrowOutline.shadowOffset = CGSize(width: 0, height: 1)
        arrow.path = Self.arrowPath
        arrow.fillColor = color.copy(alpha: Self.dartTint.alpha)
        arrow.strokeColor = Self.rim
        arrow.lineWidth = 1.4
        arrow.lineJoin = .round
        let box = Self.arrowPath.boundingBoxOfPath
        arrowSheen.frame = box
        arrowSheen.colors = Self.dartSheen
        arrowSheen.startPoint = CGPoint(x: 0, y: 0)
        arrowSheen.endPoint = CGPoint(x: 1, y: 1)
        let sheenMask = CAShapeLayer()
        var toSheen = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        sheenMask.path = Self.arrowPath.copy(using: &toSheen)
        arrowSheen.mask = sheenMask
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
        caption.cornerCurve = .continuous
        caption.shadowColor = CGColor(gray: 0, alpha: 1)
        caption.shadowOpacity = 0.16
        caption.shadowRadius = 5
        caption.shadowOffset = .zero
        caption.cornerRadius = Self.tagStyle.cornerRadius
        caption.anchorPoint = .zero
        caption.opacity = 0
        captionText.font = Self.captionFont
        captionText.fontSize = Self.captionFontSize
        captionText.foregroundColor = Self.glassText
        captionText.alignmentMode = .center
        captionText.truncationMode = .start
        caption.addSublayer(captionText)
        nameTag.cornerCurve = .continuous
        nameTag.masksToBounds = false
        nameTag.shadowColor = CGColor(gray: 0, alpha: 1)
        nameTag.shadowOpacity = 0.18
        nameTag.shadowRadius = 4
        nameTag.shadowOffset = CGSize(width: 0, height: 1.5)
        nameDot.fillColor = Self.gray
        nameTag.addSublayer(nameDot)
        nameTag.cornerRadius = Self.tagStyle.cornerRadius
        nameTag.anchorPoint = .zero
        nameText.font = Self.captionFont
        nameText.fontSize = Self.tagFontSize
        nameText.foregroundColor = Self.glassText
        nameText.alignmentMode = .center
        nameText.truncationMode = .end
        nameText.contentsScale = scale
        nameTag.addSublayer(nameText)
        for (rim, pill) in [(nameRim, nameTag), (captionRim, caption)] {
            // y-down layers: the gradient's start (the bright end) is the top edge.
            rim.startPoint = CGPoint(x: 0.5, y: 0)
            rim.endPoint = CGPoint(x: 0.5, y: 1)
            let stroke = CAShapeLayer()
            stroke.fillColor = nil
            stroke.strokeColor = CGColor(gray: 0, alpha: 1)
            stroke.lineWidth = 1 / scale
            rim.mask = stroke
            pill.addSublayer(rim)
        }
        applyGlass()
        if let name, !name.isEmpty {
            let padding: CGFloat = 9, dot: CGFloat = 6, gap: CGFloat = 5
            let lead = padding + dot + gap
            let width = Self.captionWidth(name, size: Self.tagFontSize) + lead + padding
            nameTag.frame = CGRect(origin: Self.tagOffset, size: CGSize(width: width, height: Self.tagHeight))
            Self.layoutRim(nameRim, in: nameTag.bounds)
            nameDot.path = CGPath(ellipseIn: CGRect(x: padding, y: (Self.tagHeight - dot) / 2, width: dot, height: dot), transform: nil)
            let lineHeight = ceil(Self.tagFontSize * 1.3)
            nameText.frame = CGRect(x: lead, y: (Self.tagHeight - lineHeight) / 2, width: width - lead - padding, height: lineHeight)
            nameText.string = name
        } else {
            nameTag.isHidden = true
        }
        glassRoot.bounds = root.bounds
        glassRoot.anchorPoint = .zero
        glassHeading.bounds = heading.bounds
        glassHeading.anchorPoint = .zero
        glassArrow.path = Self.arrowPath
        glassArrow.fillColor = CGColor(gray: 0, alpha: 1)
        glassHeading.addSublayer(glassArrow)
        glassRoot.addSublayer(glassHeading)
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
        heading.addSublayer(arrowOutline)
        heading.addSublayer(arrow)
        heading.addSublayer(arrowSheen)
        root.addSublayer(heading)
        root.addSublayer(indicator)
        root.addSublayer(nameTag)
        root.addSublayer(caption)
    }

    static let tagFontSize: CGFloat = 11
    static let tagHeight: CGFloat = 22
    /// The name tag's resting top-left corner from the arrow tip: in the hollow
    /// behind the notch, below the right wing and right of the lower one, so
    /// it never covers the tip or the body (``AgentCursorTagLayout/restingOffset``).
    static let tagOffset = AgentCursorTagLayout.restingOffset

    static let captionFontSize: CGFloat = 12
    static let captionHeight: CGFloat = 22
    /// The caption's font, the bold system font (made per use: a CTFont is not Sendable).
    static var captionFont: CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, captionFontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, captionFontSize, nil)
    }
    /// The visible page the cursor is in, in host-layer coordinates; nil
    /// before the host knew it (the tag then rests below-right of the tip).
    var confinement: CGRect?
    /// Which side of the tip the tag is on now; kept between placements so an
    /// edge flips the tag once, not on every move (``AgentCursorTagLayout``).
    private(set) var tagLayout = AgentCursorTagLayout.resting

    /// Lays the name tag and caption out for the tip at `tip` (host-layer
    /// coordinates, where the cursor is or is about to be) so they stay inside
    /// ``confinement``. A flip moves on the shared movement spring; under
    /// Reduce Motion or with animations off it moves at once.
    func layOutTag(tip: CGPoint, snapCaption: Bool = false) {
        let showsCaption = isCaptionShowing || snapCaption
        if let bounds = confinement {
            // The side fits the tag and the caption stacked under (or over) it,
            // so the caption never has to be pushed back over the tag.
            let tag = hasName ? nameTag.bounds.size : .zero
            let note = showsCaption ? caption.bounds.size : .zero
            let gap: CGFloat = hasName && showsCaption ? AgentCursorTagLayout.captionGap : 0
            let block = CGSize(width: max(tag.width, note.width), height: tag.height + gap + note.height)
            tagLayout = tagLayout.next(size: block, tip: tip, bounds: bounds)
        } else {
            tagLayout = .resting
        }
        if hasName {
            let tag = tagLayout.frame(size: nameTag.bounds.size, tip: tip, bounds: confinement)
            let origin = CGPoint(x: tag.minX - tip.x, y: tag.minY - tip.y)
            if nameTag.frame.origin != origin { move(nameTag, glassTag, to: origin, snap: false) }
        }
        if caption.bounds.width > 0 {
            let origin = captionFrame(size: caption.bounds.size, tip: tip).origin
            if caption.frame.origin != origin { move(caption, glassCaption, to: origin, snap: snapCaption) }
        }
        hasTip = true
    }

    /// The caption shows now (typed text not faded out yet).
    var isCaptionShowing: Bool {
        caption.bounds.width > 0 && (caption.presentation() ?? caption).opacity > 0.01
    }

    /// Moves a pill and its blur well together (both have a zero anchor, so
    /// `position` is the top-left corner). It glides on the movement spring
    /// only when the cursor is already showing; a first placement, a hidden
    /// cursor, Reduce Motion or animations off move it at once.
    private func move(_ pill: CALayer, _ well: CALayer, to origin: CGPoint, snap: Bool) {
        let animates = !snap && hasTip && !root.isHidden && !showsIndicator
        for layer in [pill, well] {
            if animates {
                Motion.cursor.set(layer, "position", to: NSValue(point: origin), spring: .move)
            } else {
                layer.removeAnimation(forKey: "position")
                layer.position = origin
            }
        }
    }

    /// The tip was laid out at least once, so a later flip may animate.
    private var hasTip = false

    /// The caption's frame relative to the tip: beside the tag, away from the
    /// tip, inside ``confinement``.
    private func captionFrame(size: CGSize, tip: CGPoint) -> CGRect {
        let tag = hasName ? nameTag.frame.offsetBy(dx: tip.x, dy: tip.y) : nil
        let frame = tagLayout.captionFrame(size: size, tag: tag, tip: tip, bounds: confinement)
        return frame.offsetBy(dx: -tip.x, dy: -tip.y)
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
        let wasShowing = isCaptionShowing
        let size = CGSize(width: width, height: Self.captionHeight)
        for layer in [caption, glassCaption] { layer.bounds = CGRect(origin: .zero, size: size) }
        let lineHeight = ceil(Self.captionFontSize * 1.3)
        captionText.frame = CGRect(x: padding, y: (Self.captionHeight - lineHeight) / 2,
                                   width: width - padding * 2, height: lineHeight)
        captionText.contentsScale = scale
        captionText.string = text
        Self.layoutRim(captionRim, in: caption.bounds)
        // A caption that was gone appears in place; a showing one glides with a flip.
        layOutTag(tip: root.position, snapCaption: !wasShowing)
        for layer in [caption, glassCaption] {
            layer.opacity = 1
            layer.removeAnimation(forKey: Self.captionHideKey)
            layer.add(Motion.cursor.scheduledFade(.cursorHide, "opacity", from: 1, to: 0, after: Self.captionHideDelay, on: layer),
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
            arrow.fillColor = isPaused ? nil : fill.copy(alpha: Self.dartTint.alpha)
            arrow.strokeColor = isPaused ? fill : Self.rim
            arrowSheen.isHidden = isPaused
            glassArrow.isHidden = isPaused || showsIndicator
        }
    }

    /// Reduce Transparency is on: the tag and caption draw opaque, with no rim, like every
    /// shared glass surface (`OverlayMaterial.opaque`).
    public var reducesTransparency = false {
        didSet { if reducesTransparency != oldValue { applyGlass() } }
    }

    /// Paints the tag and caption in the shared glass for the current state.
    private func applyGlass() {
        let look = Self.tagStyle.look(isDark: false)
        let veil = look.veil
        let alpha = reducesTransparency ? 1 : min(veil.alpha + (isTagHighlighted ? Self.hoverVeilBoost : 0), 1)
        let fill = CGColor(srgbRed: veil.white, green: veil.white, blue: veil.white, alpha: alpha)
        let rimColors = [look.rimTop, look.rimBottom].map { CGColor(srgbRed: $0.white, green: $0.white, blue: $0.white, alpha: $0.alpha) }
        for (pill, rim) in [(nameTag, nameRim), (caption, captionRim)] {
            pill.backgroundColor = fill
            pill.borderWidth = 0
            rim.colors = rimColors
            rim.isHidden = reducesTransparency
        }
        let shadow = Self.tagStyle.castsShadow && !reducesTransparency
        nameTag.shadowOpacity = shadow ? 0.18 : 0
        caption.shadowOpacity = shadow ? 0.16 : 0
    }

    /// Sizes a rim to its pill: a hairline just inside the capsule's edge.
    private static func layoutRim(_ rim: CAGradientLayer, in bounds: CGRect) {
        rim.frame = bounds
        guard let stroke = rim.mask as? CAShapeLayer else { return }
        stroke.frame = bounds
        let inset = bounds.insetBy(dx: stroke.lineWidth / 2, dy: stroke.lineWidth / 2)
        let radius = min(max(tagStyle.cornerRadius - stroke.lineWidth / 2, 0), min(inset.width, inset.height) / 2)
        stroke.path = inset.width > 0 && inset.height > 0
            ? CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
    }

    /// The pointer is on the tag (it is a link to the agent's workspace): a
    /// denser veil of the same shared glass.
    public var isTagHighlighted = false {
        didSet { if isTagHighlighted != oldValue { applyGlass() } }
    }

    /// The target is hidden: a dot at its tab chip or column edge, no arrow.
    public var showsIndicator = false {
        didSet {
            indicator.isHidden = !showsIndicator
            heading.isHidden = showsIndicator
            glassArrow.isHidden = showsIndicator || isPaused
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
            layer.add(Motion.cursor.scheduledFade(.cursorHide, "opacity", from: 1, to: 0, after: delay, on: layer), forKey: Self.idleHideKey)
        }
    }

    static let idleHideKey = "agentCursor.idleHide"

    /// Click feedback: the ripple grows and fades (`MotionFade.clickPulse`,
    /// 0.25 s at the fast speed, cmux-cua timing). Reduce Motion keeps only
    /// the fade, at the ring's full size; speed "off" shows no ripple.
    func pulse() {
        if Motion.cursor.set(ripple, "transform.scale", to: 1.6, movementFade: .clickPulse, from: 0.4) == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ripple.transform = CATransform3DMakeScale(1.6, 1.6, 1)
            CATransaction.commit()
        }
        Motion.cursor.set(ripple, "opacity", to: 0, fade: .clickPulse, from: 0.9)
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
