#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Contact avatar: monogram on the Messages gray gradient, or the participant tint.
final class ConversationAvatarView: UIView {
    private let gradient = CAGradientLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(gradient)
        label.textAlignment = .center
        label.textColor = .white
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
        clipsToBounds = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(initials: String, colorHex: String?) {
        label.text = initials
        let base: UIColor
        if let colorHex {
            base = ConversationTheme.color(hex: colorHex)
        } else {
            base = UIColor(red: 0.62, green: 0.65, blue: 0.70, alpha: 1)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        gradient.colors = [
            UIColor(hue: h, saturation: s * 0.85, brightness: min(1, b * 1.12), alpha: 1).cgColor,
            UIColor(hue: h, saturation: s, brightness: b * 0.82, alpha: 1).cgColor,
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        gradient.frame = bounds
        label.frame = bounds.insetBy(dx: bounds.width * 0.12, dy: 0)
        label.font = .systemFont(ofSize: bounds.width * 0.40, weight: .semibold)
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

    static func size(count: Int) -> CGSize {
        let s = ConversationTheme.reactionBadgeSize
        return CGSize(width: s + CGFloat(max(0, min(count, 3) - 1)) * s * 0.55 + 6, height: s + 6)
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
        let large: CGFloat = 9, small: CGFloat = 4.5
        if pointsLeft {
            dotLarge.frame = CGRect(x: 4, y: s - large * 0.55, width: large, height: large)
            dotSmall.frame = CGRect(x: 0, y: s + large * 0.45, width: small, height: small)
        } else {
            dotLarge.frame = CGRect(x: bubble.frame.maxX - large - 4, y: s - large * 0.55, width: large, height: large)
            dotSmall.frame = CGRect(x: bubble.frame.maxX - small, y: s + large * 0.45, width: small, height: small)
        }
        dotLarge.layer.cornerRadius = large / 2
        dotSmall.layer.cornerRadius = small / 2
    }
}

/// Three dots pulsing in sequence inside an incoming bubble.
final class TypingIndicatorView: UIView {
    private let bubble = BubbleBackgroundView()
    private let tailLarge = UIView()
    private let tailSmall = UIView()
    private var dots: [UIView] = []

    static let bubbleSize = CGSize(width: 62, height: 42)

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.side = .leading
        bubble.hasTail = false
        bubble.fillColor = ConversationTheme.incomingBubble
        addSubview(tailSmall)
        addSubview(tailLarge)
        addSubview(bubble)
        for _ in 0..<3 {
            let dot = UIView()
            dot.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.55, alpha: 1) }
            dot.layer.cornerRadius = 4.5
            bubble.addSubview(dot)
            dots.append(dot)
        }
        for view in [tailLarge, tailSmall] { view.backgroundColor = ConversationTheme.incomingBubble }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = Self.bubbleSize
        bubble.frame = CGRect(x: 0, y: 0, width: size.width + ConversationTheme.tailWidth, height: size.height)
        let body = bubble.bounds.inset(by: UIEdgeInsets(top: 0, left: ConversationTheme.tailWidth, bottom: 0, right: 0))
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: body.minX + 14 + CGFloat(index) * 13, y: body.midY - 4.5, width: 9, height: 9)
        }
        tailLarge.frame = CGRect(x: ConversationTheme.tailWidth - 2, y: size.height - 9, width: 12, height: 12)
        tailLarge.layer.cornerRadius = 6
        tailSmall.frame = CGRect(x: ConversationTheme.tailWidth - 6, y: size.height + 3, width: 6, height: 6)
        tailSmall.layer.cornerRadius = 3
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stopAnimating() : startAnimating()
    }

    func startAnimating() {
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAllAnimations()
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.35, 1.0, 0.35, 0.35]
            pulse.keyTimes = [0, 0.22, 0.44, 1]
            pulse.duration = 1.3
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            pulse.repeatCount = .infinity
            dot.layer.add(pulse, forKey: "pulse")
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.9, 1.08, 0.9, 0.9]
            scale.keyTimes = [0, 0.22, 0.44, 1]
            scale.duration = 1.3
            scale.beginTime = pulse.beginTime
            scale.repeatCount = .infinity
            dot.layer.add(scale, forKey: "scale")
        }
        // The whole bubble breathes slightly, as in Messages.
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.98
        breathe.toValue = 1.02
        breathe.duration = 1.1
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        bubble.layer.add(breathe, forKey: "breathe")
    }

    func stopAnimating() {
        dots.forEach { $0.layer.removeAllAnimations() }
        bubble.layer.removeAllAnimations()
    }
}
#endif
