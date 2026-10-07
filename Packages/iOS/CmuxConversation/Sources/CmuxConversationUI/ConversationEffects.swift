#if canImport(UIKit)
import CmuxConversationCore
import UIKit

// Messages "send with effect" rendering: the bubble effects (Slam, Loud,
// Gentle) as keyframed transforms on a bubble copy, Invisible Ink as a
// particle cover with a touch reveal, and the eight screen effects as a
// non-interactive overlay. Everything is Core Animation driven, so a
// playback ends through animation completion, never through a timer.

extension ConversationMessageEffect {
    var localizedName: String {
        switch self {
        case .slam: return String(localized: "conversation.effect.slam", defaultValue: "Slam", bundle: .module)
        case .loud: return String(localized: "conversation.effect.loud", defaultValue: "Loud", bundle: .module)
        case .gentle: return String(localized: "conversation.effect.gentle", defaultValue: "Gentle", bundle: .module)
        case .invisibleInk: return String(localized: "conversation.effect.invisibleInk", defaultValue: "Invisible Ink", bundle: .module)
        case .echo: return String(localized: "conversation.effect.echo", defaultValue: "Echo", bundle: .module)
        case .spotlight: return String(localized: "conversation.effect.spotlight", defaultValue: "Spotlight", bundle: .module)
        case .balloons: return String(localized: "conversation.effect.balloons", defaultValue: "Balloons", bundle: .module)
        case .confetti: return String(localized: "conversation.effect.confetti", defaultValue: "Confetti", bundle: .module)
        case .love: return String(localized: "conversation.effect.love", defaultValue: "Love", bundle: .module)
        case .lasers: return String(localized: "conversation.effect.lasers", defaultValue: "Lasers", bundle: .module)
        case .fireworks: return String(localized: "conversation.effect.fireworks", defaultValue: "Fireworks", bundle: .module)
        case .celebration: return String(localized: "conversation.effect.celebration", defaultValue: "Celebration", bundle: .module)
        }
    }

    /// VoiceOver and caption text, "Sent with Slam".
    var sentWithDescription: String {
        String(format: String(localized: "conversation.effect.sentWith", defaultValue: "Sent with %@", bundle: .module), localizedName)
    }
}

enum ConversationEffectStrings {
    static var replay: String { String(localized: "conversation.effect.replay", defaultValue: "Replay", bundle: .module) }
    static var sendWithEffect: String { String(localized: "conversation.effect.sendWithEffect", defaultValue: "Send with effect", bundle: .module) }
    static var bubble: String { String(localized: "conversation.effect.bubble", defaultValue: "Bubble", bundle: .module) }
    static var screen: String { String(localized: "conversation.effect.screen", defaultValue: "Screen", bundle: .module) }
    static var cancel: String { String(localized: "conversation.effect.cancel", defaultValue: "Cancel", bundle: .module) }
    static var reveal: String { String(localized: "conversation.effect.reveal", defaultValue: "Reveal", bundle: .module) }
    static var inkHidden: String { String(localized: "conversation.effect.inkHidden", defaultValue: "Hidden with Invisible Ink", bundle: .module) }
}

// MARK: - Bubble effects

/// Keyframes for the bubble effects. Values are scales/offsets of the whole
/// bubble around its center; `impactTime` is when Slam lands.
enum BubbleEffectAnimation {
    static func duration(_ effect: ConversationMessageEffect, reduceMotion: Bool) -> CFTimeInterval {
        if reduceMotion { return 0.3 }
        switch effect {
        case .slam: return 0.85
        case .loud: return 1.55
        case .gentle: return 2.6
        default: return 0
        }
    }

    /// Fraction of the Slam duration at which the bubble hits its slot.
    static let slamImpact: Double = 0.3

    /// Builds the animation group to add to a bubble copy's layer. The layer's
    /// anchor must be the bubble center.
    /// Growth is pinned to the sender's edge (`side`), so a large Slam or
    /// Loud bubble swells into the transcript instead of off screen.
    static func make(_ effect: ConversationMessageEffect, bubbleSize: CGSize, side: BubbleShape.Side, reduceMotion: Bool) -> CAAnimation? {
        let duration = duration(effect, reduceMotion: reduceMotion)
        guard duration > 0 else { return nil }
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = duration
            return fade
        }
        // Half the width, signed so scaling keeps the sender-side edge fixed.
        let shift = (side == .trailing ? -1 : 1) * bubbleSize.width / 2
        func sc(_ s: CGFloat, dy: CGFloat) -> CATransform3D { scaled(s, dy: dy, shift: shift) }
        let group = CAAnimationGroup()
        group.duration = duration
        group.fillMode = .backwards
        switch effect {
        case .slam:
            // Large and lifted above its slot, it drops in a quarter second,
            // squashes on impact, and settles.
            let lift = -max(60, bubbleSize.height * 1.4)
            let transform = CAKeyframeAnimation(keyPath: "transform")
            let i = slamImpact
            transform.keyTimes = [0, NSNumber(value: i), NSNumber(value: i + 0.08), NSNumber(value: i + 0.2), NSNumber(value: i + 0.32), 1]
            transform.values = [
                sc(2.6, dy: lift), sc(1, dy: 0), sc(0.94, dy: 2), sc(1.03, dy: -1), sc(1, dy: 0), sc(1, dy: 0),
            ].map { NSValue(caTransform3D: $0) }
            transform.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear),
            ]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.keyTimes = [0, 0.12, 1]
            opacity.values = [0, 1, 1]
            group.animations = [transform, opacity]
        case .loud:
            // Swells to almost twice its size, shouts (a fast rotational
            // shake), then shrinks back.
            var times: [NSNumber] = [0, 0.16]
            var values: [CATransform3D] = [sc(1, dy: 0), sc(1.9, dy: -bubbleSize.height * 0.45)]
            let shakes = 8
            for k in 0..<shakes {
                let t = 0.16 + 0.44 * Double(k + 1) / Double(shakes)
                let angle = (k % 2 == 0 ? 1.0 : -1.0) * 0.045 * (1 - Double(k) / Double(shakes + 2))
                times.append(NSNumber(value: t))
                values.append(CATransform3DRotate(sc(1.9, dy: -bubbleSize.height * 0.45), CGFloat(angle), 0, 0, 1))
            }
            times.append(contentsOf: [0.62, 0.86, 1])
            values.append(contentsOf: [sc(1.9, dy: -bubbleSize.height * 0.45), sc(1, dy: 0), sc(1, dy: 0)])
            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.keyTimes = times
            transform.values = values.map { NSValue(caTransform3D: $0) }
            transform.calculationMode = .cubic
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.keyTimes = [0, 0.06, 1]
            opacity.values = [0, 1, 1]
            group.animations = [transform, opacity]
        case .gentle:
            // Appears small and quiet, holds, then slowly grows to size.
            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.keyTimes = [0, 0.22, 0.92, 1]
            transform.values = [sc(0.42, dy: 0), sc(0.45, dy: 0), sc(1.0, dy: 0), sc(1, dy: 0)].map { NSValue(caTransform3D: $0) }
            transform.timingFunctions = [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1),
                CAMediaTimingFunction(name: .linear),
            ]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.keyTimes = [0, 0.12, 1]
            opacity.values = [0, 1, 1]
            group.animations = [transform, opacity]
        default:
            return nil
        }
        return group
    }

    private static func scaled(_ s: CGFloat, dy: CGFloat, shift: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation(shift * (s - 1), dy, 0), s, s, 1)
    }
}

/// A copy of a message bubble (fill, tail, text) that effects animate, so
/// the real cell views keep their layout and state untouched.
final class MessageBubbleStage: UIView {
    let bubble = BubbleBackgroundView()
    let label = UILabel()
    private(set) var ink: InvisibleInkView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.numberOfLines = 0
        addSubview(bubble)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `bubbleFrame` and `textFrame` are in the coordinates of this view's
    /// eventual superview; the stage takes the bubble frame.
    func configure(side: BubbleShape.Side, tail: Bool, fill: UIColor, text: NSAttributedString, bubbleFrame: CGRect, textFrame: CGRect) {
        frame = bubbleFrame
        bubble.side = side
        bubble.hasTail = tail
        bubble.fillColor = fill
        bubble.frame = bounds
        label.attributedText = text
        label.frame = textFrame.offsetBy(dx: -bubbleFrame.minX, dy: -bubbleFrame.minY)
    }

    /// Center of the bubble body (tail excluded), in this view's bounds.
    var bodyCenter: CGPoint {
        var body = bounds
        body.size.width -= ConversationTheme.tailWidth
        if bubble.side == .leading { body.origin.x += ConversationTheme.tailWidth }
        return CGPoint(x: body.midX, y: body.midY)
    }

    func setInk(_ on: Bool, outgoing: Bool, animated: Bool = false) {
        if on {
            let ink = self.ink ?? InvisibleInkView()
            if self.ink == nil {
                addSubview(ink)
                self.ink = ink
            }
            ink.attach(cover: label, bubblePath: BubbleShape.path(in: bounds, side: bubble.side, tail: bubble.hasTail).cgPath, outgoing: outgoing)
            ink.frame = bounds
            ink.cover(animated: animated)
        } else {
            ink?.removeFromSuperview()
            ink = nil
            label.layer.mask = nil
            label.alpha = 1
        }
    }

    /// Plays a bubble effect on this stage around the bubble center.
    func play(_ effect: ConversationMessageEffect, side: BubbleShape.Side, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard let animation = BubbleEffectAnimation.make(effect, bubbleSize: bounds.size, side: side, reduceMotion: reduceMotion) else {
            completion()
            return
        }
        let center = bodyCenter
        let oldFrame = frame
        layer.anchorPoint = CGPoint(x: center.x / max(1, bounds.width), y: center.y / max(1, bounds.height))
        frame = oldFrame
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(animation, forKey: "messageEffect")
        CATransaction.commit()
    }
}

// MARK: - Invisible Ink

/// Shimmering particles that hide a message's text. Touches wipe the
/// particles away around the finger; the cover returns a few seconds after
/// the last touch.
final class InvisibleInkView: UIView {
    /// The view the ink hides (the text label); revealed through a mask.
    private weak var covered: UIView?
    private let emitter = CAEmitterLayer()
    private let emitterMask = CAShapeLayer()
    private let coveredMask = CAShapeLayer()
    private var bubblePath: CGPath?
    private var revealPath = CGMutablePath()
    private var outgoing = true
    private(set) var isRevealed = false
    /// The transcript row this ink covers; a reused cell re-covers for a new row.
    var rowID: String?
    /// Radius of the area one touch point clears.
    static let revealRadius: CGFloat = 34
    /// Seconds after the last touch before the ink re-covers the text.
    static let recoverDelay: TimeInterval = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .surface
        emitter.renderMode = .unordered
        emitterMask.fillRule = .evenOdd
        emitter.mask = emitterMask
        layer.addSublayer(emitter)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(cover view: UIView, bubblePath: CGPath, outgoing: Bool) {
        covered = view
        self.bubblePath = bubblePath
        self.outgoing = outgoing
        view.layer.mask = coveredMask
        coveredMask.fillColor = UIColor.black.cgColor
        configureCell()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterSize = bounds.insetBy(dx: 6, dy: 4).size
        // Particle density follows area, like Messages (dense, fine dust).
        emitter.birthRate = 1
        emitter.emitterCells?.first?.birthRate = Self.birthRate(for: bounds.size)
        updateMasks()
        CATransaction.commit()
    }

    private func configureCell() {
        let cell = CAEmitterCell()
        cell.contents = Self.dotImage.cgImage
        cell.lifetime = 1.6
        cell.lifetimeRange = 0.8
        cell.velocity = 4
        cell.velocityRange = 8
        cell.emissionRange = .pi * 2
        cell.scale = 0.14
        cell.scaleRange = 0.08
        cell.alphaRange = 0.6
        cell.alphaSpeed = -0.55
        cell.color = (outgoing ? UIColor.white : UIColor(white: traitCollection.userInterfaceStyle == .dark ? 0.9 : 0.25, alpha: 1)).cgColor
        cell.birthRate = Self.birthRate(for: bounds.size)
        emitter.emitterCells = [cell]
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle { configureCell() }
    }

    private func updateMasks() {
        let full = CGMutablePath()
        if let bubblePath { full.addPath(bubblePath) } else { full.addRect(bounds) }
        full.addPath(revealPath)
        emitterMask.path = full
        // The covered view sits inside this view's superview; map the reveal into it.
        if let covered, let superview {
            let origin = covered.convert(CGPoint.zero, to: self)
            var shift = CGAffineTransform(translationX: -origin.x, y: -origin.y)
            coveredMask.path = revealPath.copy(using: &shift)
            _ = superview
        }
    }

    /// Clears the ink around `point` (this view's coordinates).
    func reveal(at point: CGPoint) {
        cancelRecover()
        let r = Self.revealRadius
        revealPath.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
        isRevealed = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateMasks()
        CATransaction.commit()
    }

    func revealAll() {
        cancelRecover()
        revealPath = CGMutablePath()
        revealPath.addRect(bounds.insetBy(dx: -40, dy: -40))
        isRevealed = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        updateMasks()
        CATransaction.commit()
    }

    /// The finger lifted: the ink drifts back after a delay.
    func scheduleRecover() {
        guard isRevealed else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + Self.recoverDelay
        fade.duration = 0.01
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.layer.animation(forKey: "recover") != nil || self.pendingRecover else { return }
            self.pendingRecover = false
            self.cover(animated: true)
        }
        pendingRecover = true
        layer.add(fade, forKey: "recover")
        CATransaction.commit()
    }

    private var pendingRecover = false

    private func cancelRecover() {
        pendingRecover = false
        layer.removeAnimation(forKey: "recover")
    }

    func cover(animated: Bool) {
        cancelRecover()
        revealPath = CGMutablePath()
        isRevealed = false
        if animated, let covered {
            // Particles return over the text while it fades.
            UIView.animate(withDuration: 0.6, delay: 0, options: [.allowUserInteraction]) {
                covered.alpha = 0
            } completion: { [weak self] _ in
                guard let self, !self.isRevealed else { return }
                self.updateMasks()
                covered.alpha = 1
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let full = CGMutablePath()
            if let bubblePath { full.addPath(bubblePath) } else { full.addRect(bounds) }
            emitterMask.path = full
            CATransaction.commit()
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.6
            emitter.add(fadeIn, forKey: "fadeIn")
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateMasks()
            CATransaction.commit()
        }
    }

    /// Fine dust: about one live particle per 9 square points.
    static func birthRate(for size: CGSize) -> Float {
        Float(max(30, size.width * size.height / 14))
    }

    static let dotImage: UIImage = {
        let size = CGSize(width: 6, height: 6)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()
}

// MARK: - Screen effects

/// A full-screen, non-interactive overlay that plays one screen effect.
final class ScreenEffectView: UIView {
    private(set) var effect: ConversationMessageEffect?
    private var finished = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func duration(_ effect: ConversationMessageEffect) -> CFTimeInterval {
        switch effect {
        case .echo: return 3.6
        case .spotlight: return 3.6
        case .balloons: return 5.0
        case .confetti: return 4.6
        case .love: return 3.2
        case .lasers: return 4.4
        case .fireworks: return 4.6
        case .celebration: return 4.2
        default: return 0
        }
    }

    /// Plays `effect` once. `anchor` is the message bubble in this view's
    /// coordinates; `bubble` builds a copy of it (Echo). Completion runs once.
    func play(
        _ effect: ConversationMessageEffect,
        anchor: CGRect,
        bubble: (() -> UIView?)? = nil,
        completion: @escaping () -> Void
    ) {
        self.effect = effect
        clear()
        let duration = Self.duration(effect)
        guard duration > 0 else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        // A carrier animation fixes the playback length.
        let carrier = CABasicAnimation(keyPath: "zPosition")
        carrier.fromValue = 0
        carrier.toValue = 0
        carrier.duration = duration
        layer.add(carrier, forKey: "screenEffect")
        switch effect {
        case .balloons: playBalloons(duration)
        case .confetti: playConfetti(duration)
        case .love: playLove(anchor: anchor, duration: duration)
        case .lasers: playLasers(anchor: anchor, duration: duration)
        case .fireworks: playFireworks(duration)
        case .celebration: playCelebration(duration)
        case .echo: playEcho(anchor: anchor, bubble: bubble, duration: duration)
        case .spotlight: playSpotlight(anchor: anchor, duration: duration)
        default: break
        }
        CATransaction.commit()
    }

    func stop() {
        layer.removeAllAnimations()
        clear()
    }

    /// Views first: removing a subview's layer behind UIKit's back corrupts the view tree.
    private func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: Helpers

    private func dim(alpha: CGFloat, duration: CFTimeInterval, fadeIn: CFTimeInterval = 0.35, fadeOut: CFTimeInterval = 0.5) -> CALayer {
        let dim = CALayer()
        dim.frame = bounds
        dim.backgroundColor = UIColor.black.cgColor
        dim.opacity = 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = [0, NSNumber(value: fadeIn / duration), NSNumber(value: 1 - fadeOut / duration), 1]
        fade.values = [0, alpha, alpha, 0]
        fade.duration = duration
        dim.add(fade, forKey: "dim")
        layer.addSublayer(dim)
        return dim
    }

    private func emitterBurst(_ emitter: CAEmitterLayer, on: CFTimeInterval, off: CFTimeInterval, total: CFTimeInterval, begin: CFTimeInterval = 0) {
        // birthRate is a multiplier on every cell: 1 while emitting, 0 after.
        emitter.birthRate = 0
        let rate = CAKeyframeAnimation(keyPath: "birthRate")
        rate.keyTimes = [0, NSNumber(value: on / total), NSNumber(value: off / total), NSNumber(value: min(1, off / total + 0.0001)), 1]
        rate.values = [0, 1, 1, 0, 0]
        rate.calculationMode = .discrete
        rate.duration = total
        rate.beginTime = begin > 0 ? CACurrentMediaTime() + begin : 0
        rate.fillMode = .both
        emitter.add(rate, forKey: "burst")
    }

    static let palette: [UIColor] = [
        UIColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        UIColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        UIColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        UIColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        UIColor(red: 1.00, green: 0.18, blue: 0.57, alpha: 1),
    ]

    // MARK: Balloons

    private func playBalloons(_ duration: CFTimeInterval) {
        var rng = SystemRandomNumberGenerator()
        let count = 12
        for index in 0..<count {
            let color = Self.palette[index % Self.palette.count]
            let width = CGFloat.random(in: 64...86, using: &rng)
            let image = Self.balloonImage(color: color, width: width)
            let balloon = CALayer()
            balloon.contents = image.cgImage
            balloon.contentsScale = image.scale
            balloon.bounds = CGRect(origin: .zero, size: image.size)
            let startX = CGFloat.random(in: 0.05...0.95, using: &rng) * bounds.width
            let startY = bounds.maxY + image.size.height / 2 + CGFloat.random(in: 0...160, using: &rng)
            let endY = -image.size.height
            balloon.position = CGPoint(x: startX, y: endY)
            let rise = CAKeyframeAnimation(keyPath: "position")
            let path = UIBezierPath()
            path.move(to: CGPoint(x: startX, y: startY))
            let sway = CGFloat.random(in: 18...36, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            path.addCurve(
                to: CGPoint(x: startX + sway * 0.5, y: endY),
                controlPoint1: CGPoint(x: startX + sway, y: startY - (startY - endY) * 0.35),
                controlPoint2: CGPoint(x: startX - sway, y: startY - (startY - endY) * 0.7)
            )
            rise.path = path.cgPath
            let travel = CFTimeInterval.random(in: 3.0...3.9, using: &rng)
            let delay = CFTimeInterval(index) / CFTimeInterval(count) * (duration - travel - 0.1)
            rise.duration = travel
            rise.beginTime = CACurrentMediaTime() + delay
            rise.fillMode = .backwards
            rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.7, 1)
            balloon.add(rise, forKey: "rise")
            let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            wobble.values = [-0.08, 0.08, -0.08]
            wobble.duration = 1.6
            wobble.repeatCount = .infinity
            wobble.calculationMode = .cubic
            balloon.add(wobble, forKey: "wobble")
            layer.addSublayer(balloon)
        }
    }

    static func balloonImage(color: UIColor, width: CGFloat) -> UIImage {
        let bodyHeight = width * 1.2
        let stringLength = width * 1.1
        let size = CGSize(width: width, height: bodyHeight + stringLength)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let body = CGRect(x: 0, y: 0, width: width, height: bodyHeight)
            // Body: a soft vertical gradient with a highlight, like a latex balloon.
            cg.saveGState()
            let path = UIBezierPath(ovalIn: body)
            path.addClip()
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            let light = UIColor(hue: hue, saturation: sat * 0.75, brightness: min(1, bri * 1.15), alpha: 1)
            let dark = UIColor(hue: hue, saturation: sat, brightness: bri * 0.72, alpha: 1)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [light.cgColor, dark.cgColor] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(gradient, startCenter: CGPoint(x: width * 0.38, y: bodyHeight * 0.32), startRadius: 2, endCenter: CGPoint(x: width / 2, y: bodyHeight / 2), endRadius: width * 0.7, options: [.drawsAfterEndLocation])
            UIColor(white: 1, alpha: 0.45).setFill()
            UIBezierPath(ovalIn: CGRect(x: width * 0.22, y: bodyHeight * 0.14, width: width * 0.2, height: bodyHeight * 0.16)).fill()
            cg.restoreGState()
            // Knot and string.
            dark.setFill()
            let knot = UIBezierPath()
            knot.move(to: CGPoint(x: width / 2 - 5, y: bodyHeight + 5))
            knot.addLine(to: CGPoint(x: width / 2 + 5, y: bodyHeight + 5))
            knot.addLine(to: CGPoint(x: width / 2, y: bodyHeight - 2))
            knot.close()
            knot.fill()
            let string = UIBezierPath()
            string.move(to: CGPoint(x: width / 2, y: bodyHeight + 5))
            string.addCurve(to: CGPoint(x: width / 2, y: size.height), controlPoint1: CGPoint(x: width / 2 + 8, y: bodyHeight + stringLength * 0.35), controlPoint2: CGPoint(x: width / 2 - 8, y: bodyHeight + stringLength * 0.7))
            UIColor(white: 0.55, alpha: 0.9).setStroke()
            string.lineWidth = 1.2
            string.stroke()
        }
    }

    // MARK: Confetti

    private func playConfetti(_ duration: CFTimeInterval) {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: -12)
        emitter.emitterSize = CGSize(width: bounds.width * 1.1, height: 1)
        emitter.renderMode = .oldestLast
        emitter.emitterCells = Self.palette.flatMap { color -> [CAEmitterCell] in
            [Self.confettiCell(color: color, image: Self.confettiRect), Self.confettiCell(color: color, image: Self.confettiCurl)]
        }
        emitterBurst(emitter, on: 0, off: duration * 0.45, total: duration)
        layer.addSublayer(emitter)
    }

    private static func confettiCell(color: UIColor, image: UIImage) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image.cgImage
        cell.color = color.cgColor
        cell.birthRate = 7
        cell.lifetime = 5
        cell.velocity = 170
        cell.velocityRange = 70
        cell.yAcceleration = 120
        cell.emissionLongitude = .pi
        cell.emissionRange = .pi / 5
        cell.spin = 3
        cell.spinRange = 6
        cell.scale = 0.55
        cell.scaleRange = 0.25
        return cell
    }

    static let confettiRect: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 6)).image { _ in
        UIColor.white.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 12, height: 6))
    }

    static let confettiCurl: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 10)).image { _ in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 1, y: 8))
        path.addQuadCurve(to: CGPoint(x: 13, y: 2), controlPoint: CGPoint(x: 7, y: -2))
        path.lineWidth = 3
        path.lineCapStyle = .round
        UIColor.white.setStroke()
        path.stroke()
    }

    // MARK: Love

    private func playLove(anchor: CGRect, duration: CFTimeInterval) {
        let size = min(bounds.width * 0.72, 300)
        let heart = CALayer()
        let image = Self.heartImage(size: size)
        heart.contents = image.cgImage
        heart.contentsScale = image.scale
        heart.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let start = CGPoint(x: anchor.midX, y: anchor.minY)
        let rest = CGPoint(
            x: min(max(anchor.midX, size / 2 + 8), bounds.width - size / 2 - 8),
            y: max(size / 2 + 60, anchor.minY - size * 0.55)
        )
        heart.position = rest
        heart.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let position = CAKeyframeAnimation(keyPath: "position")
        position.keyTimes = [0, 0.25, 0.8, 1]
        position.values = [start, rest, rest, CGPoint(x: rest.x, y: rest.y - 40)].map { NSValue(cgPoint: $0) }
        position.duration = duration
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        // Inflates out of the bubble, beats twice, then deflates back toward it.
        scale.keyTimes = [0, 0.25, 0.35, 0.42, 0.52, 0.6, 0.8, 1]
        scale.values = [0.08, 1.0, 1.12, 0.98, 1.12, 1.0, 1.0, 0.3]
        scale.duration = duration
        scale.calculationMode = .cubic
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.keyTimes = [0, 0.1, 0.82, 1]
        opacity.values = [0, 1, 1, 0]
        opacity.duration = duration
        let group = CAAnimationGroup()
        group.animations = [position, scale, opacity]
        group.duration = duration
        heart.opacity = 0
        heart.add(group, forKey: "love")
        layer.addSublayer(heart)
    }

    static func heartImage(size: CGFloat) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.82, weight: .regular)
        let symbol = UIImage(systemName: "heart.fill", withConfiguration: config)?
            .withTintColor(UIColor(red: 1, green: 0.17, blue: 0.33, alpha: 1), renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            guard let symbol else { return }
            let rect = CGRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: rect)
            // A glossy highlight on the upper lobe.
            UIColor(white: 1, alpha: 0.28).setFill()
            UIBezierPath(ovalIn: CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.12, width: rect.width * 0.22, height: rect.height * 0.16)).fill()
        }
    }

    // MARK: Lasers

    private func playLasers(anchor: CGRect, duration: CFTimeInterval) {
        _ = dim(alpha: 0.88, duration: duration)
        let origin = CGPoint(x: anchor.midX, y: anchor.minY - 8)
        let beams = 7
        let colors = [UIColor.systemPink, .systemBlue, .systemGreen, .systemPurple, .systemTeal, .systemYellow, .systemRed]
        let length = hypot(bounds.width, bounds.height) * 1.2
        for index in 0..<beams {
            let beam = CAShapeLayer()
            let path = UIBezierPath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: -length))
            beam.path = path.cgPath
            beam.lineWidth = 3
            beam.lineCap = .round
            beam.strokeColor = colors[index % colors.count].cgColor
            beam.shadowColor = beam.strokeColor
            beam.shadowRadius = 8
            beam.shadowOpacity = 1
            beam.shadowOffset = .zero
            beam.position = origin
            beam.opacity = 0
            let spread = CGFloat(index) / CGFloat(beams - 1) - 0.5
            let sweep = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let base = spread * 1.6
            sweep.values = [base - 0.5, base + 0.5, base - 0.5]
            sweep.duration = 1.4 + Double(index % 3) * 0.2
            sweep.repeatCount = .infinity
            sweep.calculationMode = .cubic
            beam.add(sweep, forKey: "sweep")
            let hue = CAKeyframeAnimation(keyPath: "strokeColor")
            hue.values = (0..<colors.count).map { colors[($0 + index) % colors.count].cgColor } + [colors[index % colors.count].cgColor]
            hue.duration = 1.2
            hue.repeatCount = .infinity
            beam.add(hue, forKey: "hue")
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.keyTimes = [0, 0.12, 0.85, 1]
            fade.values = [0, 1, 1, 0]
            fade.duration = duration
            beam.add(fade, forKey: "fade")
            layer.addSublayer(beam)
        }
    }

    // MARK: Fireworks

    private func playFireworks(_ duration: CFTimeInterval) {
        _ = dim(alpha: 0.82, duration: duration)
        var rng = SystemRandomNumberGenerator()
        let bursts = 5
        for index in 0..<bursts {
            let emitter = CAEmitterLayer()
            emitter.frame = bounds
            emitter.emitterShape = .point
            emitter.emitterPosition = CGPoint(
                x: CGFloat.random(in: 0.2...0.8, using: &rng) * bounds.width,
                y: CGFloat.random(in: 0.15...0.5, using: &rng) * bounds.height
            )
            emitter.renderMode = .additive
            let color = Self.palette[(index * 2) % Self.palette.count]
            let cell = CAEmitterCell()
            cell.contents = Self.sparkImage.cgImage
            cell.color = color.cgColor
            cell.birthRate = 2600
            cell.lifetime = 1.7
            cell.lifetimeRange = 0.4
            cell.velocity = 210
            cell.velocityRange = 30
            cell.emissionRange = .pi * 2
            cell.yAcceleration = 70
            cell.alphaSpeed = -0.6
            cell.scale = 0.13
            cell.scaleSpeed = -0.05
            cell.greenRange = 0.2
            cell.redRange = 0.2
            emitter.emitterCells = [cell]
            let begin = 0.25 + Double(index) * (duration - 2.2) / Double(bursts)
            emitterBurst(emitter, on: 0, off: 0.06, total: duration - begin, begin: begin)
            layer.addSublayer(emitter)
        }
    }

    static let sparkImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
        let colors = [UIColor.white.cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 8, y: 8), startRadius: 0, endCenter: CGPoint(x: 8, y: 8), endRadius: 8, options: [])
    }

    // MARK: Celebration

    private func playCelebration(_ duration: CFTimeInterval) {
        _ = dim(alpha: 0.55, duration: duration)
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterShape = .point
        emitter.emitterPosition = CGPoint(x: bounds.maxX + 10, y: -10)
        emitter.renderMode = .additive
        let gold = CAEmitterCell()
        gold.contents = Self.sparkImage.cgImage
        gold.color = UIColor(red: 1, green: 0.82, blue: 0.35, alpha: 1).cgColor
        gold.birthRate = 260
        gold.lifetime = 2.6
        gold.lifetimeRange = 0.8
        gold.velocity = 360
        gold.velocityRange = 160
        gold.emissionLongitude = .pi * 0.72
        gold.emissionRange = .pi / 7
        gold.alphaSpeed = -0.35
        gold.scale = 0.28
        gold.scaleRange = 0.18
        gold.redRange = 0.1
        gold.greenRange = 0.15
        emitter.emitterCells = [gold]
        emitterBurst(emitter, on: 0.2, off: duration * 0.6, total: duration)
        layer.addSublayer(emitter)
    }

    // MARK: Echo

    private func playEcho(anchor: CGRect, bubble: (() -> UIView?)?, duration: CFTimeInterval) {
        var rng = SystemRandomNumberGenerator()
        let copies = 22
        for index in 0..<copies {
            guard let copy = bubble?() else { return }
            let scale = CGFloat.random(in: 0.55...1.05, using: &rng)
            let start = CGPoint(
                x: CGFloat.random(in: 0.1...0.9, using: &rng) * bounds.width,
                y: bounds.height * CGFloat.random(in: 0.35...1.05, using: &rng)
            )
            copy.center = start
            copy.layer.opacity = 0
            addSubview(copy)
            let travel = CABasicAnimation(keyPath: "position")
            travel.fromValue = NSValue(cgPoint: start)
            travel.toValue = NSValue(cgPoint: CGPoint(x: start.x + CGFloat.random(in: -30...30, using: &rng), y: start.y - bounds.height * CGFloat.random(in: 0.45...0.8, using: &rng)))
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.keyTimes = [0, 0.15, 0.75, 1]
            fade.values = [0, 1, 1, 0]
            let size = CABasicAnimation(keyPath: "transform.scale")
            size.fromValue = scale * 0.6
            size.toValue = scale
            let group = CAAnimationGroup()
            group.animations = [travel, fade, size]
            group.duration = 2.2
            group.beginTime = CACurrentMediaTime() + Double(index) / Double(copies) * (duration - 2.3)
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            copy.layer.add(group, forKey: "echo")
        }
    }

    // MARK: Spotlight

    private func playSpotlight(anchor: CGRect, duration: CFTimeInterval) {
        let shade = CAShapeLayer()
        shade.frame = bounds
        shade.fillRule = .evenOdd
        shade.fillColor = UIColor.black.withAlphaComponent(0.86).cgColor
        let radius = max(anchor.width, anchor.height) / 2 + 34
        func path(center: CGPoint, radius: CGFloat) -> CGPath {
            let p = CGMutablePath()
            p.addRect(bounds)
            p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            return p
        }
        let target = CGPoint(x: anchor.midX, y: anchor.midY)
        let wander = CGPoint(x: bounds.width * 0.25, y: bounds.height * 0.3)
        shade.path = path(center: target, radius: radius)
        let move = CAKeyframeAnimation(keyPath: "path")
        move.keyTimes = [0, 0.3, 1]
        move.values = [path(center: wander, radius: radius * 1.2), path(center: target, radius: radius), path(center: target, radius: radius)]
        move.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        move.duration = duration
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = [0, 0.1, 0.85, 1]
        fade.values = [0, 1, 1, 0]
        fade.duration = duration
        shade.opacity = 0
        shade.add(move, forKey: "move")
        shade.add(fade, forKey: "fade")
        layer.addSublayer(shade)
        // The light itself: a soft glow on the message.
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [UIColor(white: 1, alpha: 0.22).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: target.x - radius, y: target.y - radius, width: radius * 2, height: radius * 2)
        glow.opacity = 0
        glow.add(fade, forKey: "fade")
        layer.addSublayer(glow)
    }
}
#endif
