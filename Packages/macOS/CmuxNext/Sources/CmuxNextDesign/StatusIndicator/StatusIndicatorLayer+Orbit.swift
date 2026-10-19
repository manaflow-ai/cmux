import AppKit
import QuartzCore

/// The Orbit set's working mark (`StatusIconSet.orbit`, Leo 2026-10-18 after Claude Code's working
/// mark): four dots on a circle that turn slowly around the slot and draw in to a tight cluster and
/// back out twice a turn. One `CAReplicatorLayer` around one dot, a quarter turn apart, so it costs
/// one sublayer like the other glyphs; the whole motion is one keyframe path on the dot, run by the
/// render server with no timer. Nothing fades: the dots move, they never blink. A turn takes two
/// Motion `pulse` periods and each regroup one, so at the fastest Debug Settings period the dots
/// regroup at most twice a second (the 2 Hz cap, cx-sya4n). Still (loops off, hidden, occluded),
/// the dots stand spread on the axes where a turn starts; Reduce Motion and the Static mode draw the
/// static look instead (`StatusIndicatorPlan.make`).
extension StatusIndicatorLayer {
    nonisolated static let orbitCount = 4
    /// Dot diameter as a share of the glyph square.
    nonisolated static let orbitDotShare: CGFloat = 0.26
    /// The circle the dots draw in to, as a share of the square: the dots about touch.
    nonisolated static let orbitInnerShare: CGFloat = 0.18
    /// Points on the dot's path per turn.
    nonisolated static let orbitSamples = 96

    /// The dot's center radii, spread and drawn in, in a square of `side`.
    nonisolated static func orbitRadii(side: CGFloat) -> (outer: CGFloat, inner: CGFloat) {
        (side / 2 - side * orbitDotShare / 2, side * orbitInnerShare)
    }

    func buildOrbit(in rect: CGRect) {
        let replicator = orbitLayer ?? {
            let replicator = CAReplicatorLayer()
            replicator.actions = Self.noActions
            let dot = CAShapeLayer()
            dot.actions = Self.noActions
            dot.lineWidth = 0
            replicator.addSublayer(dot)
            layer.addSublayer(replicator)
            orbitLayer = replicator
            return replicator
        }()
        if replicator.frame != rect {
            replicator.frame = rect
            // The turn's keyframes are points in this frame (a row is configured before it is laid
            // out): drop the old turn so `updateAnimation` starts one in the new frame.
            replicator.sublayers?.first?.removeAnimation(forKey: "orbit")
        }
        replicator.instanceCount = Self.orbitCount
        // Applied about the replicator's center: each copy a quarter turn on.
        replicator.instanceTransform = CATransform3DMakeRotation(2 * .pi / CGFloat(Self.orbitCount), 0, 0, 1)
        guard let dot = replicator.sublayers?.first as? CAShapeLayer else { return }
        let side = rect.width * Self.orbitDotShare
        dot.contentsScale = contentsScale
        dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.position = Self.orbitPoint(turn: 0, in: replicator.bounds)
    }

    func removeOrbit() {
        orbitLayer?.removeFromSuperlayer()
        orbitLayer = nil
    }

    /// Where the first dot's center is `turn` (0..<1) through a turn: clockwise from the top, spread
    /// at the start and halfway, drawn in at a quarter and three quarters.
    nonisolated static func orbitPoint(turn: CGFloat, in bounds: CGRect) -> CGPoint {
        let (outer, inner) = orbitRadii(side: min(bounds.width, bounds.height))
        let radius = inner + (outer - inner) * (1 + cos(4 * .pi * turn)) / 2
        let angle = 2 * .pi * turn
        return CGPoint(x: bounds.midX + radius * sin(angle), y: bounds.midY + radius * cos(angle))
    }

    /// The turn on the first dot; the copies follow a quarter turn apart. Nil when loops are
    /// stopped (`Motion.period`).
    func orbitAnimation() -> CAAnimation? {
        guard let period = Motion.period(.pulse), let bounds = orbitLayer?.bounds else { return nil }
        let orbit = CAKeyframeAnimation(keyPath: "position")
        orbit.values = (0...Self.orbitSamples).map { index in
            NSValue(point: Self.orbitPoint(turn: CGFloat(index) / CGFloat(Self.orbitSamples), in: bounds))
        }
        orbit.duration = 2 * period
        orbit.repeatCount = .infinity
        orbit.isRemovedOnCompletion = false
        return orbit
    }
}
