import CoreGraphics
import QuartzCore

/// Scrolling without a scroll view: the host turns its scroll events into
/// deltas; the scene moves the offset, recycles rows and keeps the morph,
/// the outgoing gradient and the pinned state in step.
extension HomeScene {
    /// Scrolls by `dy` points (positive reveals older rows). Clamped, no bounce.
    /// Returns true when the offset moved.
    @discardableResult
    func scroll(by dy: CGFloat) -> Bool {
        let y = clamped(offset - dy)
        guard y != offset else {
            if dy < 0, pinnedOffset - y < 1 { pinned = true }
            return false
        }
        let d = y - offset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setOffset(y)
        layoutRows()
        morphs.values.forEach { $0.scroll(by: d) }
        for (_, r) in visible {
            if let i = visibleIndex[ObjectIdentifier(r)], i < model.count { r.windowY = windowY(contentY: layout.frame(for: i).minY) }
        }
        pinned = pinnedOffset - y < 1
        CATransaction.commit()
        return true
    }

    /// True when the viewport is within one screen of the oldest loaded row.
    var nearOldest: Bool { offset - minOffset < size.height }

    // MARK: Momentum (hosts without system momentum events)

    /// Starts a decaying fling at `velocity` pt/s (positive reveals older rows).
    func beginMomentum(velocity: CGFloat, at time: CFTimeInterval) {
        momentum = abs(velocity) > 20 ? (velocity, time) : nil
    }

    /// One display frame of momentum; false once it stopped. The decay is the
    /// system trackpad's (x0.92 per 120 Hz frame).
    func stepMomentum(at time: CFTimeInterval) -> Bool {
        guard var m = momentum else { return false }
        let rate = HomeMotion.momentumFrameRate
        let frames = max(0, min(0.05, time - m.last)) * rate
        let d = m.velocity / CGFloat(rate) * CGFloat(frames)
        m.velocity *= CGFloat(pow(HomeMotion.momentumDecayPerFrame, frames))
        m.last = time
        let moved = scroll(by: d)
        if (d != 0 && !moved) || abs(m.velocity) / CGFloat(rate) < 0.1 {
            momentum = nil
            return false
        }
        momentum = m
        return true
    }
}
