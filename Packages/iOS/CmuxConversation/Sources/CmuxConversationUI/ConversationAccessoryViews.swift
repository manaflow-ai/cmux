#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import CoreImage
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

/// How a tapback glyph draws. Messages uses ChatKit's own artwork, the last
/// frame of each tapback's animation in its asset catalog (`heart_108`,
/// `thumbsup_073`, `thumbsdown_069`, `haha-ENG_114`, `exclamation_103`,
/// `question_080`; the same names on iOS 26.5 and 27.0), drawn at 32 pt.
/// The images are read by name from the system ChatKit bundle with public
/// API only, as the + menu reads its art; when that bundle or image is
/// missing, color emoji and tinted lettering stand in.
@MainActor
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

    private static let chatKit: Bundle? = {
        var path = "/System/Library/PrivateFrameworks/ChatKit.framework"
        #if targetEnvironment(simulator)
        if let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] { path = root + path }
        #endif
        return Bundle(path: path)
    }()

    /// ChatKit's HA HA comes per script; Japanese gets its own, others English.
    private static var hahaVariant: String {
        let language = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "" } ?? ""
        switch language {
        case "ja": return "JPN"
        case "ar": return "ARA"
        case "zh": return "CHN"
        case "ru", "uk", "be", "bg", "sr", "kk": return "CYR"
        case "es": return "ESP"
        case "he": return "HEB"
        case "hi": return "HIN"
        case "it": return "ITA"
        case "ko": return "KOR"
        case "th": return "THA"
        default: return "ENG"
        }
    }

    static func chatKitImageName(for reaction: ConversationReaction) -> String? {
        switch reaction {
        case .heart: return "heart_108"
        case .thumbsup: return "thumbsup_073"
        case .thumbsdown: return "thumbsdown_069"
        case .haha: return "haha-\(hahaVariant)_114"
        case .exclamation: return "exclamation_103"
        case .question: return "question_080"
        case .emoji: return nil
        }
    }

    static func chatKitImage(for reaction: ConversationReaction) -> UIImage? {
        guard let chatKit, let name = chatKitImageName(for: reaction) else { return nil }
        return UIImage(named: name, in: chatKit, compatibleWith: nil)
    }

    /// A transcript badge's glyph: ChatKit's art, or the drawn fallback. On
    /// my own tapback (the blue platter) Messages recolors the art with a
    /// color matrix on the image view (`CKTapbackClassicView`, selected):
    /// the heart a touch brighter, the others to a white-to-blue ramp of
    /// their luminance. The matrices are ChatKit's, read from the layer.
    static func badgeView(for reaction: ConversationReaction, size: CGFloat, selected: Bool = false) -> UIView {
        if let image = chatKitImage(for: reaction) {
            let view = UIImageView(image: selected ? (selectedImage(for: reaction, base: image) ?? image) : image)
            view.contentMode = .scaleAspectFit
            return view
        }
        return view(for: reaction, size: size)
    }

    /// CAFilter `colorMatrix` rows (r, g, b, a, bias) on a selected tapback,
    /// iOS 27.0 Messages.
    static func selectedMatrix(for reaction: ConversationReaction) -> [CGFloat]? {
        switch reaction {
        case .heart: return [0.988, 0, 0, 0, 0.089, 0, 0.988, 0, 0, 0.089, 0, 0, 0.988, 0, 0.089, 0, 0, 0, 1, 0]
        case .thumbsup: return [0.482, 1.621, 0.164, 0, -0.881, 0.244, 0.822, 0.083, 0, 0.046, 0.120, 0.405, 0.041, 0, 0.530, 0, 0, 0, 1, 0]
        case .thumbsdown: return [0.481, 1.618, 0.163, 0, -0.724, 0.240, 0.808, 0.082, 0, 0.142, 0.117, 0.393, 0.040, 0, 0.585, 0, 0, 0, 1, 0]
        case .haha: return [0.205, 0.690, 0.070, 0, 0.197, 0.115, 0.386, 0.039, 0, 0.595, 0, 0, 0, 0, 1.095, 0, 0, 0, 1, 0]
        case .exclamation: return [0.216, 0.726, 0.073, 0, 0.205, 0.120, 0.404, 0.041, 0, 0.595, 0, 0, 0, 0, 1.080, 0, 0, 0, 1, 0]
        case .question: return [0.216, 0.726, 0.073, 0, 0.216, 0.120, 0.404, 0.041, 0, 0.599, 0, 0, 0, 0, 1.075, 0, 0, 0, 1, 0]
        case .emoji: return nil
        }
    }

    private static var selectedCache: [String: UIImage] = [:]

    private static func selectedImage(for reaction: ConversationReaction, base: UIImage) -> UIImage? {
        guard let name = chatKitImageName(for: reaction), let m = selectedMatrix(for: reaction) else { return nil }
        if let cached = selectedCache[name] { return cached }
        guard let cg = base.cgImage else { return nil }
        let filter = CIFilter(name: "CIColorMatrix")
        filter?.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: m[0], y: m[1], z: m[2], w: m[3]), forKey: "inputRVector")
        filter?.setValue(CIVector(x: m[5], y: m[6], z: m[7], w: m[8]), forKey: "inputGVector")
        filter?.setValue(CIVector(x: m[10], y: m[11], z: m[12], w: m[13]), forKey: "inputBVector")
        filter?.setValue(CIVector(x: m[15], y: m[16], z: m[17], w: m[18]), forKey: "inputAVector")
        filter?.setValue(CIVector(x: m[4], y: m[9], z: m[14], w: m[19]), forKey: "inputBiasVector")
        guard let output = filter?.outputImage,
              let rendered = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
                .createCGImage(output, from: CIImage(cgImage: cg).extent) else { return nil }
        let image = UIImage(cgImage: rendered, scale: base.scale, orientation: base.imageOrientation)
        selectedCache[name] = image
        return image
    }

    /// Drawn glyph (color emoji, tinted lettering).
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

/// The tapback badge on a bubble's top corner, as ChatKit's
/// `CKTapbackPlatterView` (iOS 26.5 and 27.0): a 34 pt disc and two dots
/// trailing away from the bubble, each ringed 0.5 pt in the page color so the
/// badge stands off the bubble, holding the 32 pt glyph. Mine sit on the
/// iMessage blue gradient; others' on the received-bubble gray. Geometry in
/// `ConversationTapbackGeometry`. With several kinds, the platters pile up
/// behind the first, each shifted toward the dots.
final class ReactionBadgeView: UIView {
    private var outlines: [UIView] = []
    private var fills: [UIView] = []
    private let fillContainer = UIView()
    private let fillMask = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private var glyphViews: [UIView] = []
    private(set) var reactions: [ConversationReaction] = []
    private var mine = false
    /// Dots trail left (a sent bubble's top-left corner) unless mirrored.
    var pointsLeft = false { didSet { if oldValue != pointsLeft { setNeedsLayout() } } }

    /// Each extra kind in the pile sits this far toward the dots.
    static let pileStep: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for _ in 0..<3 {
            let outline = UIView()
            outline.layer.cornerCurve = .continuous
            outlines.append(outline)
            addSubview(outline)
        }
        fillContainer.layer.mask = fillMask
        fillContainer.layer.addSublayer(gradient)
        addSubview(fillContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(reactions: [ConversationReaction], mine: Bool) {
        self.reactions = reactions
        self.mine = mine
        glyphViews.forEach { $0.removeFromSuperview() }
        glyphViews = reactions.prefix(3).map { TapbackGlyph.badgeView(for: $0, size: ConversationTapbackGeometry.glyphSize, selected: mine) }
        for glyph in glyphViews.reversed() { addSubview(glyph) }
        updateColors()
        setNeedsLayout()
    }

    /// Frame for a badge of `count` kinds whose first platter is `platter`.
    static func frame(count: Int, platter: CGRect, pointsLeft: Bool) -> CGRect {
        let extra = CGFloat(max(0, min(count, 3) - 1)) * pileStep
        return CGRect(x: platter.minX - (pointsLeft ? extra : 0), y: platter.minY, width: platter.width + extra, height: platter.height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        let traits = traitCollection
        for outline in outlines { outline.backgroundColor = ConversationTheme.background.resolvedColor(with: traits) }
        fillContainer.backgroundColor = mine ? nil : ConversationTheme.incomingBubble.resolvedColor(with: traits)
        gradient.isHidden = !mine
        updateScreenGradient()
    }

    /// Mine fill: the iMessage gradient at the badge's place on screen, as
    /// ChatKit's `CKAggregateAcknowledgmentGradientBalloonView` fills it
    /// against the same gradient reference view as the bubbles. (Right after
    /// reacting, Messages keeps the colors it sampled in the context menu's
    /// lifted preview until the cell is configured again; we always use the
    /// in-place colors.)
    func updateScreenGradient() {
        guard mine, let window, window.bounds.height > 0 else { return }
        let frame = convert(bounds, to: window)
        let span = ConversationTranscriptMetrics.gradientSpan(windowHeight: window.bounds.height, bottomSafeInset: window.safeAreaInsets.bottom)
        let sample = ConversationTheme.iMessageGradient.samples(
            from: frame.minY / span,
            to: frame.maxY / span,
            traits: traitCollection
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = sample.colors
        gradient.locations = sample.locations.map { NSNumber(value: Double($0)) }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScreenGradient()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let g = ConversationTapbackGeometry.self
        let circles = g.circles(mirrored: !pointsLeft)
        let extra = bounds.width - g.platterSize.width
        // The first platter sits at the bubble end of the box; the pile
        // extends toward the dots.
        let first = CGPoint(x: pointsLeft ? extra : 0, y: 0)
        let path = UIBezierPath()
        for (index, circle) in circles.enumerated() {
            let frame = circle.offsetBy(dx: first.x, dy: first.y)
            outlines[index].frame = frame
            outlines[index].layer.cornerRadius = frame.width / 2
            path.append(UIBezierPath(ovalIn: frame.insetBy(dx: g.outlineWidth, dy: g.outlineWidth)))
        }
        // Extra kinds: a disc each behind the first, stepped toward the dots.
        let disc = circles[0].offsetBy(dx: first.x, dy: first.y)
        for index in 1..<max(1, glyphViews.count) {
            let step = CGFloat(index) * Self.pileStep * (pointsLeft ? -1 : 1)
            path.append(UIBezierPath(ovalIn: disc.offsetBy(dx: step, dy: 0).insetBy(dx: g.outlineWidth, dy: g.outlineWidth)))
        }
        fillContainer.frame = bounds
        gradient.frame = bounds
        fillMask.frame = bounds
        fillMask.path = path.cgPath
        for (index, glyph) in glyphViews.enumerated() {
            let step = CGFloat(index) * Self.pileStep * (pointsLeft ? -1 : 1)
            let center = CGPoint(x: disc.midX + step, y: disc.midY)
            glyph.frame = CGRect(x: center.x - g.glyphSize / 2, y: center.y - g.glyphSize / 2, width: g.glyphSize, height: g.glyphSize)
        }
        updateScreenGradient()
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
