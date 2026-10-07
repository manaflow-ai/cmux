import QuartzCore

/// The agent working mark (WORKING-AND-LOADING-INDICATORS): three dots in a
/// row, drawn by one `CAReplicatorLayer` around one dot, so it costs one
/// sublayer like the other glyphs. The wave is one opacity animation on the
/// dot; the replicator delays each copy by a third of the cycle, so the
/// render server runs the whole wave with no timer and no wakeup. Still
/// (Reduce Motion, hidden, occluded), the three dots stay at full strength.
extension StatusIndicatorLayer {
    /// Dot diameter as a share of the glyph square: three dots and two gaps
    /// of half a dot fill the width (3 + 2 * 0.5 = 4 dots wide).
    static let dotsDiameterShare: CGFloat = 0.25
    static let dotsCount = 3

    func buildDots(in rect: CGRect) {
        let replicator = dotsLayer ?? {
            let replicator = CAReplicatorLayer()
            replicator.actions = Self.noActions
            let dot = CAShapeLayer()
            dot.actions = Self.noActions
            dot.lineWidth = 0
            replicator.addSublayer(dot)
            layer.addSublayer(replicator)
            dotsLayer = replicator
            return replicator
        }()
        if replicator.frame != rect { replicator.frame = rect }
        let side = rect.width * Self.dotsDiameterShare
        let step = side * 1.5
        replicator.instanceCount = Self.dotsCount
        replicator.instanceTransform = CATransform3DMakeTranslation(step, 0, 0)
        guard let dot = replicator.sublayers?.first as? CAShapeLayer else { return }
        dot.contentsScale = contentsScale
        dot.frame = CGRect(x: 0, y: (rect.height - side) / 2, width: side, height: side)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
    }

    func removeDots() {
        dotsLayer?.removeFromSuperlayer()
        dotsLayer = nil
    }

    /// The pulse on the first dot; the copies follow a third of a cycle
    /// apart. Nil when loops are stopped (`Motion.period`).
    func waveAnimation() -> CAAnimation? {
        guard let period = Motion.period(.pulse), let pulse = Motion.pulseAnimation(low: Float(config.pulseLow)) else { return nil }
        dotsLayer?.instanceDelay = period / Double(Self.dotsCount)
        return pulse
    }
}
