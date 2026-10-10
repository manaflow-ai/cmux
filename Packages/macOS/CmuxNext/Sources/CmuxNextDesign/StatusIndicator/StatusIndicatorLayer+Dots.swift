import QuartzCore

/// The agent working mark (WORKING-AND-LOADING-INDICATORS): three dots in a
/// row, drawn by one `CAReplicatorLayer` around one dot, so it costs one
/// sublayer like the other glyphs. The wave is one opacity animation on the
/// dot; the replicator delays each copy by a third of the cycle, so the
/// render server runs the whole wave with no timer and no wakeup. Still
/// (Reduce Motion, hidden, occluded), the three dots stay at full strength.
/// The `bars` glyph (a status icon set's working mark) is the same
/// replicator around one short rounded bar.
extension StatusIndicatorLayer {
    static let dotsCount = 3

    func buildDots(in rect: CGRect, bars: Bool = false) {
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
        let element = StatusGlyphGeometry.repeatedElement(in: rect.size, bars: bars)
        replicator.instanceCount = Self.dotsCount
        replicator.instanceTransform = CATransform3DMakeTranslation(element.step, 0, 0)
        guard let dot = replicator.sublayers?.first as? CAShapeLayer else { return }
        dot.contentsScale = contentsScale
        dot.frame = element.frame
        dot.path = StatusGlyphGeometry.repeatedElementPath(element.frame, bars: bars)
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
