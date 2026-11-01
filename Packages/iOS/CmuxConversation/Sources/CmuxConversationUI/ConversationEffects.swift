#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
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

extension ConversationMessageEffect {
    var animationKind: ConversationEffectAnimationKind {
        ConversationEffectAnimationKind(rawValue: rawValue) ?? .slam
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
        guard let animation = ConversationBubbleEffectAnimation.make(effect.animationKind, bubbleSize: bounds.size, trailing: side == .trailing, reduceMotion: reduceMotion) else {
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
    private var configuredSize: CGSize = .zero
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
        if self.outgoing != outgoing || emitter.emitterCells == nil { configuredSize = .zero }
        self.outgoing = outgoing
        view.layer.mask = coveredMask
        coveredMask.fillColor = UIColor.black.cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        // Re-seeding the emitter restarts its particles; only on a size change.
        if bounds.size != configuredSize {
            configuredSize = bounds.size
            configureCell()
        }
        updateMasks()
        CATransaction.commit()
    }

    private func configureCell() {
        let color = outgoing ? UIColor.white : UIColor(white: traitCollection.userInterfaceStyle == .dark ? 0.85 : 0.4, alpha: 1)
        ConversationInkParticles.configure(emitter, size: bounds.size, color: color.cgColor, scale: window?.screen.scale ?? 3)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            configuredSize = .zero
            setNeedsLayout()
        }
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

}

// MARK: - Screen effects

/// A full-screen, non-interactive overlay that plays one screen effect
/// (built by the shared `ConversationScreenEffect`).
final class ScreenEffectView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isPlaying: Bool { ConversationScreenEffect.isPlaying(layer) }

    /// Plays `effect` once. `anchor` is the message bubble in this view's
    /// coordinates; `bubble` builds a copy of it (Echo). Completion runs once.
    func play(_ effect: ConversationMessageEffect, anchor: CGRect, bubble: (() -> UIView?)? = nil, completion: @escaping @MainActor () -> Void) {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        ConversationScreenEffect.play(effect.animationKind, in: layer, bounds: bounds, anchor: anchor, scale: scale, bubble: bubble.map { make in
            { () -> CALayer? in
                guard let view = make() else { return nil }
                let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
                let copy = CALayer()
                copy.contents = image.cgImage
                copy.contentsScale = image.scale
                copy.bounds = view.bounds
                return copy
            }
        }, completion: completion)
    }

    func stop() {
        ConversationScreenEffect.clear(layer)
    }
}
#endif
