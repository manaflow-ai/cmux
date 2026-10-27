public import AppKit
public import QuartzCore
public import CmuxNextDesignTokens
import CmuxNextCompatAppKit
/// A spring that runs on the render server, with no main-thread work per frame
/// (chrome-parity R2, plans/cmux-next/chrome-parity/p03-rendering.md).
///
/// `animate` sets the layer's model value to the target at once, so hit tests and the
/// next layout read the rest value, and adds one additive `CASpringAnimation` from
/// (old model - new model) to zero. A retarget is the same call: it adds one more
/// additive spring from the old model to the new one with zero initial velocity, and
/// the springs still running carry the velocity, so the presented value and its
/// velocity stay continuous. Nothing reads the presentation layer or steps a CPU
/// spring. This is Chrome's compositor rule (cc/animation/keyframe_model.h: the
/// compositor owns the animation; cc/animation/scroll_offset_animation_curve.cc
/// `UpdateTarget` keeps the velocity on a retarget); Core Animation's additive springs
/// give the same result without a curve rebuild.
///
/// A key path driven by a `RenderSpring` must not also carry a non-additive animation:
/// that would pin the presented value to its own end value.
///
/// Each call has one landing: its completion runs once, with `true` when every spring on its
/// key paths has ended (its own and the ones still running from earlier calls), or with `false`
/// at once when a newer call takes over one of its key paths. So completions run in call order,
/// and only the newest call's `true` means the layer is at rest (`RenderSpring.Landing`).
public struct RenderSpring {
    /// A call's landing: `finished` is true when the layer is at rest on the call's targets,
    /// false when a newer call took over one of its key paths first.
    public typealias Completion = @MainActor @Sendable (_ finished: Bool) -> Void

    /// The spring token.
    public let token: MotionSpring
    /// The gate that decides whether the spring runs.
    public let gate: MotionGate

    /// A spring of `token` that obeys `gate`. Prefer `gate.renderSpring(token)`.
    public init(_ token: MotionSpring, gate: MotionGate) {
        self.token = token
        self.gate = gate
    }

    /// The tuning at the current speed.
    public var parameters: SpringParameters { gate.spring(token) }

    /// Whether a change of `keyPath` on a layer shown in `view` animates: the view's display
    /// draws frames (``Motion/canAnimate(in:)``), and the gate animates movement, or, for a
    /// fade key path (``isFade(_:)``), fades (a crossfade under Reduce Motion).
    public func animates(_ keyPath: String, in view: NSView?) -> Bool {
        style(for: keyPath, shown: Motion.canAnimate(in: view)) != .snap
    }

    /// Springs `layer`'s `key` to `value`. When the gate does not animate the key path, the
    /// value shows in one frame (springs left on the key path are removed) and `completion`
    /// runs now; otherwise it runs when the layer lands (``Completion``). `view` is the view
    /// that shows `layer`, or nil only for a layer in no window.
    public func animate<Value: RenderSpringValue>(_ layer: CALayer, _ key: RenderSpringKey<Value>, to value: Value, in view: NSView?,
                                                  completion: Completion? = nil) {
        animateGroup([.init(layer, key, to: value)], in: view, completion: completion)
    }

    /// Springs the scalar `key` of `layer` (`.positionX`, `.boundsWidth`) to `value`,
    /// starting with `velocity` (units of the value per second, as a fling's release
    /// velocity). One scalar per key path, because a `CASpringAnimation` has one initial
    /// velocity normalized to its distance: a point's velocity fits only when it is parallel
    /// to the distance.
    public func animate(_ layer: CALayer, _ key: RenderSpringKey<CGFloat>, to value: CGFloat, velocity: CGFloat, in view: NSView?,
                        completion: Completion? = nil) {
        animateGroup([.init(layer, key, to: value, velocity: velocity)], in: view, completion: completion)
    }

    /// Springs a host layer and its sublayers to their rest frames on this one token, from
    /// one begin time, so a sublayer that does not scale with the host (a ring, a glow, an
    /// edge-anchored item) stays in step with it and nothing relies on `autoresizingMask`
    /// during the spring. Each layer's transform must be the identity.
    public func animateGroup(host: CALayer, to hostFrame: CGRect, sublayers: [(CALayer, CGRect)], in view: NSView?,
                             completion: Completion? = nil) {
        let frames = [(host, hostFrame)] + sublayers
        let starts = frames.map { layer, _ in (layer.position, layer.bounds.size) }
        // One outer transaction: the rest frames and their springs commit together.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, frame) in frames { layer.frame = frame }
        var moves: [Move] = []
        for ((layer, _), (position, size)) in zip(frames, starts) {
            moves.append(Move(layer, .position, from: position, to: layer.position))
            moves.append(Move(layer, .boundsSize, from: size, to: layer.bounds.size))
        }
        animateGroup(moves, in: view, completion: completion)
        CATransaction.commit()
    }

    /// Springs every move on this token from one begin time, in one transaction. A move whose
    /// key path does not animate (``animates(_:in:)``) shows its value in one frame.
    public func animateGroup(_ moves: [Move], in view: NSView?, completion: Completion? = nil) {
        let shown = Motion.canAnimate(in: view)
        Self.run(moves, styles: moves.map { style(for: $0.keyPath, shown: shown) }, trace: "render.\(token.rawValue)", completion: completion)
    }

    /// Runs each move in its `style`, from one begin time, in one transaction, with one landing
    /// (``Completion``). The caller's gate decided the styles: ``animateGroup(_:in:completion:)``, or a
    /// fade token's view move (`MotionGate.animate(_:in:frame:alpha:completion:)`).
    static func run(_ moves: [Move], styles: [Style], trace: String, completion: Completion?) {
        let landing = Landing(completion)
        var superseded: [Landing] = []
        for (move, style) in zip(moves, styles) {
            for earlier in Landing.Table.on(move.layer).take(move.keyPath, for: landing, waits: style != .snap)
                where !superseded.contains(where: { $0 === earlier }) {
                superseded.append(earlier)
            }
        }
        let animated = zip(moves, styles).first { $0.1 != .snap }?.0
        if MotionTrace.isEnabled, let animated {
            landing.trace(trace, id: ObjectIdentifier(animated.layer))
        }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated != nil {
            CATransaction.setMainCompletion { landing.springsDidEnd() }
        }
        for (move, style) in zip(moves, styles) {
            guard style != .snap else {
                Self.stop(move.layer, move.keyPath)
                move.writeTarget()
                continue
            }
            let offset = move.offsetFromModel()
            move.writeTarget()
            let begin = move.layer.convertTime(now, from: nil)
            switch style {
            case .snap:
                break
            case .timed(let duration):
                if let offset, offset.extent > 0 {
                    Self.addFade(from: offset.value, on: move.layer, keyPath: move.keyPath, duration: duration, begin: begin, zero: move.zero)
                }
            case .spring(let spring):
                for part in Self.parts(offset: offset, velocity: move.velocity, progressVelocity: move.progressVelocity, omega: spring.omega) {
                    Self.add(part, on: move.layer, keyPath: move.keyPath, spring: spring, begin: begin, zero: move.zero)
                }
            }
        }
        CATransaction.commit()
        // The calls this one took over end first, not finished, oldest first on each layer. They run
        // after the commit, so a completion that animates the layer again takes over a set-up call.
        for earlier in superseded { earlier.supersede(by: landing) }
        // Nothing animates: the values are on screen in this frame, and the call lands now.
        if animated == nil { landing.springsDidEnd() }
    }

    // MARK: Gating

    /// How one key path's change shows.
    enum Style: Equatable {
        /// In one frame.
        case snap
        /// An additive spring with these parameters.
        case spring(SpringParameters)
        /// An additive change of this many seconds on the fade curve: a fade key path while
        /// movement is off, or any key path a fade token moves (`MotionGate.animate(_:in:frame:alpha:completion:)`).
        case timed(CFTimeInterval)

        /// How long the change runs: 0 for a snap, a spring's visible end (`perceivedDuration`, as
        /// `MotionGate.duration(_:)`), a timed change's length.
        var seconds: CFTimeInterval {
            switch self {
            case .snap: 0
            case .spring(let spring): spring.perceivedDuration
            case .timed(let seconds): seconds
            }
        }
    }

    /// Opacity is a fade in the motion policy (`animatesFades`, a crossfade under Reduce
    /// Motion), and so is a shadow's (its shape is the layer's shadowPath, which does not move);
    /// every other key path a `RenderSpringValue` animates is movement.
    public static func isFade(_ keyPath: String) -> Bool {
        keyPath == "opacity" || keyPath == "shadowOpacity"
    }

    func style(for keyPath: String, shown: Bool) -> Style {
        guard shown else { return .snap }
        if gate.animatesMovement { return .spring(parameters) }
        guard Self.isFade(keyPath), gate.animatesFades else { return .snap }
        let crossfade = gate.duration(.crossfade)
        return crossfade > 0 ? .timed(crossfade) : .snap
    }

    /// Removes the springs `RenderSpring` added on `keyPath`, on its components and on the
    /// paths it is a component of (`position.x` also takes `position`), so the layer shows
    /// its model value now.
    public static func stop(_ layer: CALayer, _ keyPath: String) {
        for key in layer.animationKeys() ?? [] {
            guard let path = springKeyPath(key), related(path, keyPath) else { continue }
            layer.removeAnimation(forKey: key)
        }
    }

    /// Whether a spring on `path` and one on `keyPath` move the same value: equal, or one is a
    /// component of the other (`position` and `position.x`, not `position.x` and `position.y`).
    static func related(_ path: String, _ keyPath: String) -> Bool {
        path == keyPath || path.hasPrefix(keyPath + ".") || keyPath.hasPrefix(path + ".")
    }

    // MARK: Moves

    /// One key path's change in a group.
    public struct Move {
        /// The layer the move springs; with ``keyPath``, what a caller stops early (``RenderSpring/stop(_:_:)``).
        public let layer: CALayer
        public let keyPath: String
        let zero: Any
        let velocity: CGFloat
        /// The share of the distance covered per second at the start, toward the target (any value type).
        let progressVelocity: CGFloat
        /// Writes the target as the layer's model value.
        let writeTarget: () -> Void
        /// The offset from the model value, read when the group starts (before ``writeTarget``).
        let offsetFromModel: () -> Offset?

        /// `layer`'s `key` springs from its model value to `value`.
        public init<Value: RenderSpringValue>(_ layer: CALayer, _ key: RenderSpringKey<Value>, to value: Value) {
            self.init(layer, key, from: nil, to: value, velocity: 0)
        }

        /// The scalar `key` of `layer` springs from its model value to `value`, starting at `velocity`.
        public init(_ layer: CALayer, _ key: RenderSpringKey<CGFloat>, to value: CGFloat, velocity: CGFloat) {
            self.init(layer, key, from: nil, to: value, velocity: velocity)
        }

        /// `from` replaces the model value read at the start (a frame already written: a pane host
        /// AppKit placed at rest in the change's turn springs from where it showed).
        public init<Value: RenderSpringValue>(_ layer: CALayer, _ key: RenderSpringKey<Value>, from: Value?, to value: Value,
                                              velocity: CGFloat = 0) {
            self.init(layer, key, from: from, to: value, velocity: velocity, progressVelocity: 0)
        }

        /// `layer`'s `key` springs from `from` to `value`, starting at `progressVelocity`: the share of the
        /// distance it covers per second at the start, toward `value`. Any value type takes it, a transform
        /// too: a `CASpringAnimation` moves every component by one progress, and its `initialVelocity` is
        /// that progress's rate.
        public init<Value: RenderSpringValue>(_ layer: CALayer, _ key: RenderSpringKey<Value>, from: Value, to value: Value,
                                              progressVelocity: CGFloat) {
            self.init(layer, key, from: from, to: value, velocity: 0, progressVelocity: progressVelocity)
        }

        private init<Value: RenderSpringValue>(_ layer: CALayer, _ key: RenderSpringKey<Value>, from: Value?, to value: Value,
                                               velocity: CGFloat, progressVelocity: CGFloat) {
            self.layer = layer
            keyPath = key.path
            zero = Value.springZero.layerValue
            self.velocity = velocity
            self.progressVelocity = progressVelocity
            writeTarget = { key.set(value, on: layer) }
            offsetFromModel = {
                guard let old = from ?? key.value(of: layer) else { return nil }
                let delta = old.springDelta(to: value)
                return Offset(value: delta.layerValue, extent: delta.springExtent, scalar: delta.springScalar)
            }
        }
    }

    /// An additive spring's start: the old value minus the new one.
    struct Offset {
        let value: Any
        /// The largest component's size, for the settling time.
        let extent: CGFloat
        /// The value as a scalar, or nil for a point, size or rect.
        let scalar: CGFloat?
    }

    /// One additive spring: its start offset, its initial velocity normalized to the offset, its extent.
    struct Part {
        let from: Any
        let normalizedVelocity: CGFloat
        let extent: CGFloat
    }

    /// The additive springs that carry `offset` at `velocity`. A scalar whose offset is too small
    /// to normalize its velocity against (a fling released at its rest value) splits into two
    /// springs, (offset + s) with the velocity and -s at rest: the sum of two solutions of the same
    /// spring is the solution with the summed start. A `progressVelocity` is already normalized
    /// (``Move/init(_:_:from:to:progressVelocity:)``), so one spring of any value type carries it.
    static func parts(offset: Offset?, velocity: CGFloat, progressVelocity: CGFloat = 0, omega: Double) -> [Part] {
        guard let offset else { return [] }
        if progressVelocity != 0 {
            guard offset.extent > 0 else { return [] }
            return [Part(from: offset.value, normalizedVelocity: progressVelocity,
                         extent: offset.extent * (1 + abs(progressVelocity) / CGFloat(omega)))]
        }
        guard let scalar = offset.scalar, velocity != 0 else {
            return offset.extent > 0 ? [Part(from: offset.value, normalizedVelocity: 0, extent: offset.extent)] : []
        }
        let reach = abs(velocity) / CGFloat(omega)
        if abs(scalar) >= reach * 1e-3 {
            return [Part(from: NSNumber(value: Double(scalar)), normalizedVelocity: -velocity / scalar, extent: abs(scalar) + reach)]
        }
        let carrier = scalar + velocity / CGFloat(omega)
        var parts = [Part(from: NSNumber(value: Double(carrier)), normalizedVelocity: -velocity / carrier, extent: abs(carrier) + reach)]
        if carrier != scalar {
            parts.append(Part(from: NSNumber(value: Double(scalar - carrier)), normalizedVelocity: 0, extent: abs(scalar - carrier)))
        }
        return parts
    }

    /// Rest within this much of the value's unit (points) or 0.2% of the move, whichever is
    /// smaller: the spring's removal at its end never steps visibly.
    static let restTolerance: CGFloat = 0.05

    /// Seconds until a spring of `extent` rests (``restTolerance``).
    static func duration(extent: CGFloat, spring: SpringParameters) -> CFTimeInterval {
        let fraction = min(0.002, Double(restTolerance / max(extent, restTolerance)))
        return spring.settlingTime(within: fraction)
    }

    private static func add(_ part: Part, on layer: CALayer, keyPath: String, spring: SpringParameters, begin: CFTimeInterval, zero: Any) {
        let animation = Motion.springAnimation(spring, keyPath)
        animation.fromValue = part.from
        animation.toValue = zero
        animation.initialVelocity = part.normalizedVelocity
        animation.isAdditive = true
        animation.beginTime = begin
        animation.duration = duration(extent: part.extent, spring: spring)
        layer.add(animation, forKey: nextKey(on: layer, keyPath: keyPath))
    }

    private static func addFade(from offset: Any, on layer: CALayer, keyPath: String, duration: CFTimeInterval,
                                begin: CFTimeInterval, zero: Any) {
        let fade = CABasicAnimation(keyPath: keyPath)
        fade.fromValue = offset
        fade.toValue = zero
        fade.isAdditive = true
        fade.beginTime = begin
        fade.duration = duration
        fade.timingFunction = Motion.fadeCurve
        layer.add(fade, forKey: nextKey(on: layer, keyPath: keyPath))
    }

    // MARK: Keys

    private static let keyPrefix = "cmux.renderSpring."

    /// A key no running spring on `layer` uses, so a retarget stacks instead of replacing:
    /// `cmux.renderSpring.<serial>.<keyPath>`, with the serial kept on the layer's landing table.
    private static func nextKey(on layer: CALayer, keyPath: String) -> String {
        let serial = Landing.Table.on(layer).nextSerial()
        return "\(keyPrefix)\(serial).\(keyPath)"
    }

    /// The key path of a key `nextKey` made, or nil for any other key.
    static func springKeyPath(_ key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let rest = key.dropFirst(keyPrefix.count)
        guard let dot = rest.firstIndex(of: "."), Int(rest[..<dot]) != nil else { return nil }
        return String(rest[rest.index(after: dot)...])
    }
}

extension Motion {
    /// A mass-1 `CASpringAnimation` of `keyPath` with `spring`'s stiffness and damping; the caller
    /// sets the values, the duration and the velocity.
    static func springAnimation(_ spring: SpringParameters, _ keyPath: String) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        return animation
    }
}

extension MotionGate {
    /// The render-server spring of `token` in this gate's category (``RenderSpring``).
    public func renderSpring(_ token: MotionSpring) -> RenderSpring {
        RenderSpring(token, gate: self)
    }
}
