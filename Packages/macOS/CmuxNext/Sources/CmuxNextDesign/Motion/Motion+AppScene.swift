public import AppKit
public import QuartzCore
public import CmuxNextDesignTokens

/// The motion an app's scene declares (the SDK motion contract: `cmux-app-host/js/ABI.md`, props
/// `animation`, `loop`, `transition`, and the `Particles` burst). Every timing of it lives here, so
/// the native scene renderer asks this file and never writes a duration or spring of its own
/// (`scripts/cmux-next/check-motion.sh`).
///
/// An app's motion obeys the person's settings through ``Motion/appScenes``: the master switch,
/// the indicators switch (`ui.animations.indicators`: an app's loops and pulses are its status
/// indicators), `ui.animationSpeed` (every time, loops included, scales with it) and Reduce Motion
/// (springs and transitions are instant, loops and particles stop).
extension Motion {
    /// The gate every app scene's motion asks (``MotionCategory/indicators``).
    public nonisolated static let appScenes = MotionGate(.indicators)
}

/// How a scene prop change animates: a spring or a timed curve. Unknown values parse to nil (no
/// animation, never a crash).
public nonisolated enum SceneMotion: Hashable, Sendable {
    case spring(SpringParameters)
    case timed(TimeInterval, SceneCurve)

    public enum SceneCurve: String, Hashable, Sendable {
        case easeOut, easeInOut, linear
    }

    /// `smooth`: the motion scale's standard step on the ease-out curve (the web's CSS step).
    public static let smooth = SceneMotion.timed(MotionScale.standard, .easeOut)
    /// `snappy`: the motion scale's micro step on the ease-out curve (the web's CSS step).
    public static let snappy = SceneMotion.timed(MotionScale.micro, .easeOut)
    /// `bouncy`: the one token that passes its target, for playful reveals.
    public static let bouncy = SceneMotion.spring(SpringParameters(response: 0.45, dampingFraction: 0.6))

    /// A named token: `smooth`, `snappy` (the motion scale's standard and micro steps), `none` (no
    /// animation), `move`, `appear`, `disappear` (the chrome's springs), `fade` (the fade-in curve),
    /// `bouncy`.
    public static func named(_ name: String) -> SceneMotion? {
        switch name {
        case "smooth": smooth
        case "move": .spring(MotionSpring.move.base)
        case "appear": .spring(MotionSpring.appear.base)
        case "disappear": .spring(MotionSpring.disappear.base)
        case "fade": .timed(MotionFade.fadeIn.baseDuration, .easeOut)
        case "snappy": snappy
        case "bouncy": bouncy
        default: nil
        }
    }

    /// `{ spring: { response, dampingFraction } }`: response clamped to [0.05, 10] s, damping to [0.3, 1].
    public static func custom(response: Double, dampingFraction: Double) -> SceneMotion? {
        guard response.isFinite, dampingFraction.isFinite else { return nil }
        return .spring(SpringParameters(response: clampedTime(response), dampingFraction: min(max(dampingFraction, 0.3), 1)))
    }

    /// `{ duration, curve? }`: duration clamped to [0.05, 10] s; `curve` defaults to `easeOut`, and an
    /// unknown curve is no animation.
    public static func timed(seconds: Double, curve: String?) -> SceneMotion? {
        guard seconds.isFinite else { return nil }
        guard let curve = curve.map(SceneCurve.init(rawValue:)) ?? .easeOut else { return nil }
        return .timed(clampedTime(seconds), curve)
    }

    static func clampedTime(_ seconds: Double) -> Double { min(max(seconds, 0.05), 10) }

    /// Seconds until it has visibly arrived, at `scale` (a crossfade of a color that has no layer
    /// property runs this long).
    public func visibleDuration(scale: Double) -> TimeInterval {
        switch self {
        case .spring(let spring): spring.scaled(by: scale).perceivedDuration
        case .timed(let seconds, _): seconds * scale
        }
    }
}

/// `loop`: an effect the renderer runs forever in the render server, with no script and no layout.
public nonisolated struct SceneLoop: Hashable, Sendable {
    public enum Effect: String, CaseIterable, Hashable, Sendable {
        case pulse, breathe, spin, float, wiggle, bounce, shimmer

        /// Seconds per cycle by default.
        public var defaultPeriod: TimeInterval {
            switch self {
            case .pulse: 1.2
            case .breathe: 3
            case .spin: 2
            case .float: 3
            case .wiggle: 0.6
            case .bounce: 0.9
            case .shimmer: 1.6
            }
        }

        /// The shortest period: nothing that changes brightness cycles faster than twice a second
        /// (`MotionLoop.shortestFlashCycle`).
        var minimumPeriod: TimeInterval {
            switch self {
            case .pulse, .breathe, .shimmer: MotionLoop.shortestFlashCycle
            case .spin, .float, .wiggle, .bounce: 0.1
            }
        }
    }

    public var effect: Effect
    public var period: TimeInterval
    /// Multiplies the effect's default amplitude.
    public var amount: Double

    /// Nil for an unknown effect. `period` in seconds (clamped to [the effect's minimum, 60]);
    /// `amount` clamped to [0, 10].
    public init?(effect: String, period: Double? = nil, amount: Double? = nil) {
        guard let effect = Effect(rawValue: effect) else { return nil }
        self.effect = effect
        let seconds = period.flatMap { $0.isFinite ? $0 : nil } ?? effect.defaultPeriod
        self.period = min(max(seconds, effect.minimumPeriod), 60)
        self.amount = min(max(amount.flatMap { $0.isFinite ? $0 : nil } ?? 1, 0), 10)
    }
}

/// `transition`: how a node enters when a render adds it (not in the first scene) and leaves when
/// one removes it, as the web renderer draws them (scene.css).
public nonisolated enum SceneTransition: String, CaseIterable, Hashable, Sendable {
    /// Opacity only.
    case opacity
    /// Up from a little below, fading in; out upward, fading.
    case slide
    /// Grows from (shrinks to) 90 % about its center, fading.
    case scale
    /// In from its leading side and out toward its trailing side, a short way, fading.
    case move
    /// Scale 0.6 to 1 on the bouncy spring, fading in; out on the disappear spring.
    case pop
}

/// The geometry a layer's own transform turns about: `pivot` is the vector from the layer's anchor
/// point to its center, in its own coordinates; `yDown` says whether +y is down on screen in the
/// space the transform applies in (the superlayer's, flipped under a flipped view).
public nonisolated struct SceneTransformSpace: Hashable, Sendable {
    public var pivot: CGPoint
    public var yDown: Bool

    public init(pivot: CGPoint, yDown: Bool) {
        self.pivot = pivot
        self.yDown = yDown
    }

    /// The space of `layer`'s own transform, at its current bounds and anchor point.
    @MainActor public init(layer: CALayer) {
        let size = layer.bounds.size
        pivot = CGPoint(x: size.width * (0.5 - layer.anchorPoint.x), y: size.height * (0.5 - layer.anchorPoint.y))
        yDown = layer.superlayer?.contentsAreFlipped() ?? true
    }

    /// Scale by `scale`, turn `degrees` clockwise on screen, both about the center, then move by
    /// `offset` points (+y down on screen).
    public func transform(scale: CGFloat = 1, degrees: CGFloat = 0, offset: CGPoint = .zero) -> CATransform3D {
        let sign: CGFloat = yDown ? 1 : -1
        var t = CATransform3DMakeTranslation(pivot.x + offset.x, pivot.y + offset.y * sign, 0)
        if degrees != 0 { t = CATransform3DRotate(t, degrees * .pi / 180 * sign, 0, 0, 1) }
        if scale != 1 { t = CATransform3DScale(t, scale, scale, 1) }
        return CATransform3DTranslate(t, -pivot.x, -pivot.y, 0)
    }
}

extension MotionGate {
    /// The animation of one prop change from `from` to `to` on `keyPath`, or nil when it applies at
    /// once (movement does not animate in `window`: Reduce Motion, speed off, a live resize).
    /// `additive`: `from` and `to` are offsets on the model value (`from` the old value less the new,
    /// `to` zero), so changes in flight add up and keep their motion.
    @MainActor public func sceneAnimation(_ motion: SceneMotion, _ keyPath: String, from: Any, to: Any,
                                          additive: Bool = false, in window: NSWindow?) -> CAAnimation? {
        guard animatesMovement(in: window) else { return nil }
        let scale = speed.timeScale
        let animation: CABasicAnimation
        switch motion {
        case .spring(let base):
            let spring = base.scaled(by: scale)
            let springy = CASpringAnimation(keyPath: keyPath)
            springy.mass = 1
            springy.stiffness = spring.stiffness
            springy.damping = spring.damping
            springy.duration = spring.settlingTime(within: 0.002)
            animation = springy
        case .timed(let seconds, let curve):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = seconds * scale
            let name: CAMediaTimingFunctionName = switch curve {
            case .easeOut: .easeOut
            case .easeInOut: .easeInEaseOut
            case .linear: .linear
            }
            animation.timingFunction = CAMediaTimingFunction(name: name)
        }
        animation.fromValue = from
        animation.toValue = to
        animation.isAdditive = additive
        return animation
    }

    /// A crossfade of `layer`'s contents over `motion`'s visible length (a text or icon color, which
    /// no layer property holds), or nil when it applies at once.
    @MainActor @discardableResult
    public func sceneCrossfade(_ motion: SceneMotion, on layer: CALayer?, in window: NSWindow?) -> CATransition? {
        guard let layer, animatesMovement(in: window) else { return nil }
        let transition = Motion.crossfadeAction
        transition.duration = motion.visibleDuration(scale: speed.timeScale)
        transition.timingFunction = fadeCurve
        layer.add(transition, forKey: "scene.crossfade")
        return transition
    }

    /// `loop`'s repeating animation, additive on the layer's model value: `transform` for the
    /// moving effects (about the center of `space`), `opacity` for `breathe`; nil when loops are off
    /// (Reduce Motion, speed off, the indicators switch) or for `shimmer` (``sceneShimmerAnimation``).
    @MainActor public func sceneLoopAnimation(_ loop: SceneLoop, in space: SceneTransformSpace) -> CAAnimation? {
        guard animatesLoops else { return nil }
        let period = loop.period * speed.timeScale
        let amount = CGFloat(loop.amount)
        let eased = CAMediaTimingFunction(name: .easeInEaseOut)
        func value(_ t: CATransform3D) -> NSValue { NSValue(caTransform3D: t) }
        func swing(_ keyPath: String, to: Any) -> CABasicAnimation {
            let swing = CABasicAnimation(keyPath: keyPath)
            swing.fromValue = keyPath == "opacity" ? NSNumber(value: 0) : value(CATransform3DIdentity)
            swing.toValue = to
            swing.duration = period / 2
            swing.autoreverses = true
            swing.timingFunction = eased
            return swing
        }
        let animation: CAPropertyAnimation
        switch loop.effect {
        case .pulse:
            animation = swing("transform", to: value(space.transform(scale: 1 + 0.06 * amount)))
        case .breathe:
            animation = swing("opacity", to: -min(0.4 * amount, 1))
        case .float:
            animation = swing("transform", to: value(space.transform(offset: CGPoint(x: 0, y: -4 * amount))))
        case .spin:
            // Matrix keyframes 10 degrees apart: a matrix cannot say a whole turn, and a turn about the
            // center moves the anchor along an arc, which close keyframes follow.
            let turns = max(amount, 0)
            let steps = max(Int((36 * turns).rounded(.up)), 1)
            let spin = CAKeyframeAnimation(keyPath: "transform")
            spin.values = (0...steps).map { value(space.transform(degrees: 360 * turns * CGFloat($0) / CGFloat(steps))) }
            spin.calculationMode = .linear
            spin.duration = period
            animation = spin
        case .wiggle:
            let wiggle = CAKeyframeAnimation(keyPath: "transform")
            let angle = 6 * amount
            wiggle.values = [0, angle, 0, -angle, 0].map { value(space.transform(degrees: $0)) }
            wiggle.timingFunctions = Array(repeating: eased, count: 4)
            wiggle.duration = period
            animation = wiggle
        case .bounce:
            let bounce = CAKeyframeAnimation(keyPath: "transform")
            bounce.values = [0, -8 * amount, 0].map { value(space.transform(offset: CGPoint(x: 0, y: $0))) }
            // Up slowing to the top, then falling faster: a ball's arc.
            bounce.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            bounce.duration = period
            animation = bounce
        case .shimmer:
            return nil
        }
        animation.isAdditive = true
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// `shimmer`: a band `band` points wide crossing `travel` points on `position.x` once per period
    /// (its anchor at the band's center), or nil when loops are off (nothing shows).
    @MainActor public func sceneShimmerAnimation(_ loop: SceneLoop, travel: CGFloat, band: CGFloat) -> CAAnimation? {
        guard animatesLoops, loop.effect == .shimmer, travel > 0 else { return nil }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -band / 2
        sweep.toValue = travel + band / 2
        sweep.duration = loop.period * speed.timeScale
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        return sweep
    }

    /// The enter (`entering`) or exit animations of `transition`, additive on the model `transform`
    /// and `opacity` (`opacity` is the node's own, so a fade reaches zero), keyed by key path; empty
    /// when it applies at once (movement does not animate in `window`). An exit holds its end until
    /// the caller removes the view.
    @MainActor public func sceneTransition(_ transition: SceneTransition, entering: Bool, opacity: Float,
                                           in space: SceneTransformSpace, window: NSWindow?) -> [String: CAAnimation] {
        guard animatesMovement(in: window) else { return [:] }
        // The web's distances (scene.css): +y is down on screen.
        let away: CATransform3D? = switch transition {
        case .opacity: nil
        case .slide: space.transform(offset: CGPoint(x: 0, y: entering ? 8 : -8))
        case .scale: space.transform(scale: 0.9)
        case .move: space.transform(offset: CGPoint(x: entering ? -12 : 12, y: 0))
        case .pop: space.transform(scale: 0.6)
        }
        let spring: SceneMotion = switch (transition, entering) {
        case (.pop, true): .bouncy
        case (_, true): .spring(MotionSpring.appear.base)
        case (_, false): .spring(MotionSpring.disappear.base)
        }
        var out: [String: CAAnimation] = [:]
        func ends(_ hidden: Any, _ shown: Any) -> (Any, Any) { entering ? (hidden, shown) : (shown, hidden) }
        if let away {
            let (from, to) = ends(NSValue(caTransform3D: away), NSValue(caTransform3D: CATransform3DIdentity))
            out["transform"] = sceneAnimation(spring, "transform", from: from, to: to, additive: true, in: window)
        }
        do {
            let fade = duration(entering ? .fadeIn : .fadeOut)
            if fade > 0 {
                let (from, to) = ends(-opacity, 0 as Float)
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = from
                animation.toValue = to
                animation.duration = fade
                animation.timingFunction = fadeCurve
                animation.isAdditive = true
                out["opacity"] = animation
            }
        }
        for animation in out.values {
            if entering {
                animation.fillMode = .backwards
            } else {
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
        }
        return out
    }

    /// A one-shot particle burst on an emitter of its own: its `birthRate` held at 1 for a tenth of
    /// a second (its model value is 0), lasting `lifetime` more seconds so the caller removes the
    /// emitter when its last particle is gone; nil when particles are off.
    @MainActor public func sceneBurstAnimation(lifetime: TimeInterval) -> CAAnimation? {
        guard animatesLoops else { return nil }
        let burst = CABasicAnimation(keyPath: "birthRate")
        burst.fromValue = 1 as Float
        burst.toValue = 1 as Float
        burst.duration = 0.1
        let life = CAAnimationGroup()
        life.animations = [burst]
        life.duration = burst.duration + min(max(lifetime, 0), 30)
        return life
    }
}
