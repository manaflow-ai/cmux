#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Contact avatar: monogram on the Contacts periwinkle gradient, or the participant tint.
final class ConversationAvatarView: UIView {
    private let gradient = CAGradientLayer()
    /// The initials draw in a layer, not a UILabel, as CNAvatar's monogram
    /// layer does: iOS 27's scroll edge pocket treats a label under the
    /// header as content to keep clear and stops its blur above the avatar.
    private let monogram = ConversationMonogramLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(gradient)
        layer.addSublayer(monogram)
        clipsToBounds = true
        isAccessibilityElement = false
        // Decorative: the sender is spoken in the bubble, the header has its own button.
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private(set) var initials = ""
    private var usesMonogramGradient = false

    func configure(initials: String, colorHex: String?) {
        self.initials = initials
        monogram.text = initials
        usesMonogramGradient = colorHex == nil
        guard let colorHex else {
            applyMonogramGradient()
            return
        }
        let base = ConversationTheme.color(hex: colorHex)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        gradient.colors = [
            UIColor(hue: h, saturation: s * 0.85, brightness: min(1, b * 1.12), alpha: 1).cgColor,
            UIColor(hue: h, saturation: s, brightness: b * 0.82, alpha: 1).cgColor,
        ]
    }

    private func applyMonogramGradient() {
        gradient.colors = ConversationTheme.monogramGradient.map { $0.resolvedColor(with: traitCollection).cgColor }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if usesMonogramGradient, previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyMonogramGradient()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        gradient.frame = bounds
        monogram.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        monogram.frame = bounds.insetBy(dx: bounds.width * 0.08, dy: 0)
        monogram.fontSize = bounds.width * ConversationTheme.monogramFontScale
    }
}

/// White semibold initials, centered, shrunk to fit down to half size
/// (what the avatar's UILabel did with `adjustsFontSizeToFitWidth`).
final class ConversationMonogramLayer: CALayer {
    var text = "" { didSet { if text != oldValue { setNeedsDisplay() } } }
    var fontSize: CGFloat = 17 { didSet { if fontSize != oldValue { setNeedsDisplay() } } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func action(forKey event: String) -> (any CAAction)? { NSNull() }

    override func draw(in context: CGContext) {
        guard !text.isEmpty, bounds.width > 0 else { return }
        var size = fontSize
        var attributes: [NSAttributedString.Key: Any] = [:]
        var textSize = CGSize.zero
        while true {
            attributes = [.font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: UIColor.white]
            textSize = (text as NSString).size(withAttributes: attributes)
            if textSize.width <= bounds.width || size <= fontSize / 2 { break }
            size = max(fontSize / 2, size * bounds.width / textSize.width)
        }
        UIGraphicsPushContext(context)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        UIGraphicsPopContext()
    }
}

/// How a tapback glyph draws: iOS 18+ renders the classic tapbacks as color
/// emoji, with HA HA, !! and ? as tinted lettering.
enum TapbackGlyph {
    static func emoji(for reaction: ConversationReaction) -> String? {
        switch reaction {
        case .heart: return "\u{1FA77}" // pink heart
        case .thumbsup: return "\u{1F44D}"
        case .thumbsdown: return "\u{1F44E}"
        case .exclamation: return "\u{203C}\u{FE0F}"
        case .haha, .question: return nil
        case .emoji(let emoji): return emoji
        }
    }

    static func view(for reaction: ConversationReaction, size: CGFloat) -> UIView {
        if let emoji = emoji(for: reaction) {
            let label = UILabel()
            label.text = emoji
            label.textAlignment = .center
            label.font = .systemFont(ofSize: size * 0.58)
            return label
        }
        switch reaction {
        case .haha:
            return textGlyph("HA\nHA", size: size * 0.27, color: UIColor(red: 0.18, green: 0.62, blue: 1.0, alpha: 1), lines: 2)
        default:
            return textGlyph("?", size: size * 0.66, color: UIColor(red: 0.62, green: 0.45, blue: 1.0, alpha: 1), lines: 1)
        }
    }

    private static func textGlyph(_ text: String, size: CGFloat, color: UIColor, lines: Int) -> UILabel {
        let label = UILabel()
        label.numberOfLines = lines
        label.textAlignment = .center
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lines > 1 ? 0.8 : 1
        style.alignment = .center
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .black),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        return label
    }
}

/// The tapback badge that hangs off a bubble's top corner, with its two
/// trailing bubble dots.
final class ReactionBadgeView: UIView {
    private let bubble = UIView()
    private let dotLarge = UIView()
    private let dotSmall = UIView()
    private var glyphViews: [UIView] = []
    private(set) var reactions: [ConversationReaction] = []
    var pointsLeft = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for view in [dotSmall, dotLarge, bubble] { addSubview(view) }
        bubble.layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(reactions: [ConversationReaction], mine: Bool) {
        self.reactions = reactions
        glyphViews.forEach { $0.removeFromSuperview() }
        glyphViews = reactions.prefix(3).map { TapbackGlyph.view(for: $0, size: ConversationTheme.reactionBadgeSize) }
        glyphViews.forEach { bubble.addSubview($0) }
        // A tapback I gave sits on blue; others' on the badge gray.
        let fill = mine ? UIColor.systemBlue : ConversationTheme.badgeFill
        for view in [bubble, dotLarge, dotSmall] { view.backgroundColor = fill }
        // Separate the badge from the bubble it overlaps with the page color.
        bubble.layer.borderWidth = 2
        bubble.layer.borderColor = ConversationTheme.background.resolvedColor(with: traitCollection).cgColor
        setNeedsLayout()
    }

    /// Room beside the circle for the trailing dots.
    static let dotInset: CGFloat = 6

    static func size(count: Int) -> CGSize {
        let s = ConversationTheme.reactionBadgeSize
        return CGSize(width: s + CGFloat(max(0, min(count, 3) - 1)) * s * 0.55 + dotInset, height: s + 10)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = ConversationTheme.reactionBadgeSize
        let width = s + CGFloat(max(0, glyphViews.count - 1)) * s * 0.55
        bubble.frame = CGRect(x: pointsLeft ? 6 : 0, y: 0, width: width, height: s)
        bubble.layer.cornerRadius = s / 2
        for (index, glyph) in glyphViews.enumerated() {
            glyph.frame = CGRect(x: CGFloat(index) * s * 0.55, y: 0, width: s, height: s).insetBy(dx: 3, dy: 3)
        }
        // Measured on Messages (d34 badge): large dot d8.5 at center
        // offset (12, 14.5), small d4.5 at (17.7, 23.3), toward the outside.
        let large: CGFloat = 9, small: CGFloat = 4.5
        let side: CGFloat = pointsLeft ? -1 : 1
        let edge = pointsLeft ? bubble.frame.minX + s / 2 : bubble.frame.maxX - s / 2
        dotLarge.frame = CGRect(x: edge + side * 12 - large / 2, y: s / 2 + 14.5 - large / 2, width: large, height: large)
        dotSmall.frame = CGRect(x: edge + side * 17.7 - small / 2, y: s / 2 + 23.3 - small / 2, width: small, height: small)
        dotLarge.layer.cornerRadius = large / 2
        dotSmall.layer.cornerRadius = small / 2
    }
}

/// Messages' typing indicator, built to ChatKit's `CKTypingIndicatorLayer`
/// (iOS 26): a 57.5 x 35 capsule with two trailing circles at its tail
/// corner and three dots that brighten in turn.
final class TypingIndicatorView: UIView {
    /// Large bubble, medium and small tail circles, each pulsing on its own period.
    private let bubble = UIView()
    private let medium = UIView()
    private let small = UIView()
    private let dotsContainer = CALayer()
    private let replicator = CAReplicatorLayer()
    private let dot = CALayer()

    static let bubbleSize = CGSize(width: 57.5, height: 35)
    // Circle frames relative to the bubble's origin (CKTypingIndicatorPunchOutLayer).
    private static let mediumFrame = CGRect(x: -0.11, y: 26.55, width: 11.5, height: 11.5)
    private static let smallFrame = CGRect(x: -4.95, y: 36.71, width: 5, height: 5)
    private static let dotDiameter: CGFloat = 8.5
    private static let dotSpacing: CGFloat = 12.5
    /// The scale pivots ChatKit gives each part (`anchorPoint`).
    private static let bubbleAnchor = CGPoint(x: 0.185, y: 0.28)
    private static let mediumAnchor = CGPoint(x: 0.326, y: 0.37)
    private static let smallAnchor = CGPoint(x: 0.318, y: 0.318)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for view in [small, medium, bubble] {
            view.backgroundColor = ConversationTheme.incomingBubble
            view.layer.cornerCurve = .circular
            addSubview(view)
        }
        bubble.layer.anchorPoint = Self.bubbleAnchor
        medium.layer.anchorPoint = Self.mediumAnchor
        small.layer.anchorPoint = Self.smallAnchor
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotDiameter, height: Self.dotDiameter)
        dot.position = CGPoint(x: Self.dotDiameter / 2, y: Self.dotDiameter / 2)
        dot.cornerRadius = Self.dotDiameter / 2
        dot.opacity = 0.2
        replicator.instanceCount = 3
        replicator.instanceTransform = CATransform3DMakeTranslation(Self.dotSpacing, 0, 0)
        replicator.instanceDelay = 0.25
        replicator.addSublayer(dot)
        dotsContainer.addSublayer(replicator)
        bubble.layer.addSublayer(dotsContainer)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The bubble's body starts at the tail column, like an incoming message.
        let origin = CGPoint(x: ConversationTheme.tailWidth, y: 0)
        func place(_ view: UIView, _ rect: CGRect) {
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            view.bounds = CGRect(origin: .zero, size: frame.size)
            view.center = CGPoint(x: frame.minX + frame.width * view.layer.anchorPoint.x, y: frame.minY + frame.height * view.layer.anchorPoint.y)
            view.layer.cornerRadius = min(frame.width, frame.height) / 2
        }
        place(bubble, CGRect(origin: .zero, size: Self.bubbleSize))
        place(medium, Self.mediumFrame)
        place(small, Self.smallFrame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotsContainer.frame = bubble.bounds
        // Three dots, centered in the bubble.
        let dotsWidth = Self.dotDiameter + 2 * Self.dotSpacing
        replicator.frame = CGRect(x: (Self.bubbleSize.width - dotsWidth) / 2, y: (Self.bubbleSize.height - Self.dotDiameter) / 2, width: dotsWidth, height: Self.dotDiameter)
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        dot.backgroundColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stopAnimating() : startAnimating()
    }

    private var parts: [(view: UIView, pulseScale: CGFloat, pulseDuration: CFTimeInterval, delay: CFTimeInterval, wobble: CGPoint)] {
        [
            (small, 1.15, 0.7, 0, CGPoint(x: 5.5, y: -2.5)),
            (medium, 1.1, 0.9, Self.mediumDelay, CGPoint(x: 5, y: 3.5)),
            (bubble, 1.03, 1.9, Self.bubbleDelay, CGPoint(x: 5, y: -6)),
        ]
    }

    private static let mediumDelay: CFTimeInterval = 0.065
    private static let bubbleDelay: CFTimeInterval = 0.12
    /// Each part's scale-up; its pulse takes over when it ends.
    private static let scaleDuration: CFTimeInterval = 0.25

    /// Starts the dots and the breathing pulse; idempotent (cells call it on
    /// every configure, and batch updates strip layer animations).
    func startAnimating() {
        if dot.animation(forKey: "dot") == nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.2
            fade.toValue = 0.45
            fade.duration = 0.5
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.757, 0.015, 0.58, 1)
            fade.fillMode = .both
            dot.add(fade, forKey: "dot")
        }
        addPulses(after: 0)
    }

    /// ChatKit's pulse (`kCKAnimationKeyPulse`): each part breathes from its
    /// own start, `delay` after now.
    private func addPulses(after delay: CFTimeInterval) {
        let now = CACurrentMediaTime()
        for part in parts where part.view.layer.animation(forKey: "pulse") == nil {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale.xy")
            pulse.values = [1, part.pulseScale, 1]
            pulse.calculationMode = .cubicPaced
            pulse.duration = part.pulseDuration
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.beginTime = now + delay + (delay > 0 ? part.delay : 0)
            pulse.fillMode = .forwards
            pulse.isRemovedOnCompletion = false
            part.view.layer.add(pulse, forKey: "pulse")
        }
    }

    /// ChatKit's insertion (`CKTypingIndicatorPunchOutLayer` grow, read
    /// from the iOS 26.5 and 27.0 runtimes, identical on both): the small
    /// circle, then the medium (+0.065 s), then the bubble (+0.12 s) scale up
    /// from nothing at their tail-side pivots (0.25 s) while each swings out
    /// along a short arc and back (0.4 s). Every part also carries ChatKit's
    /// 0.25 s `hidden` animation from the start, so the first visible frame
    /// already shows the grow under way. Each part's pulse begins as its
    /// scale-up ends (0.25 / 0.315 / 0.37 s).
    func grow() {
        let now = CACurrentMediaTime()
        let ease = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        for part in parts {
            let layer = part.view.layer
            layer.removeAnimation(forKey: "pulse")
            let hidden = CABasicAnimation(keyPath: "hidden")
            hidden.fromValue = true
            hidden.toValue = false
            hidden.duration = Self.scaleDuration
            hidden.beginTime = now
            hidden.fillMode = .forwards
            layer.add(hidden, forKey: "growHidden")
            let scale = CABasicAnimation(keyPath: "transform.scale.xy")
            scale.fromValue = 0
            scale.toValue = 1
            scale.duration = Self.scaleDuration
            scale.timingFunction = ease
            let x = CAKeyframeAnimation(keyPath: "position.x")
            x.values = [layer.position.x, layer.position.x + part.wobble.x, layer.position.x]
            x.calculationMode = .cubicPaced
            x.duration = 0.4
            x.timingFunction = ease
            let y = CAKeyframeAnimation(keyPath: "position.y")
            y.values = [layer.position.y, layer.position.y + part.wobble.y, layer.position.y]
            y.calculationMode = .cubicPaced
            y.duration = 0.4
            y.timingFunction = part.view === bubble
                ? CAMediaTimingFunction(controlPoints: 0.209, 0.258, 0.561, 0.954)
                : CAMediaTimingFunction(controlPoints: 0.332, 0.1, 0.561, 0.954)
            let group = CAAnimationGroup()
            group.animations = [scale, x, y]
            group.duration = 0.4
            group.beginTime = now + part.delay
            group.fillMode = .backwards
            layer.add(group, forKey: "grow")
        }
        addPulses(after: Self.scaleDuration)
    }

    func stopAnimating() {
        dot.removeAllAnimations()
        for part in parts { part.view.layer.removeAllAnimations() }
    }
}
#endif
