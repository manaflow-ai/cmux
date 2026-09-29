public import CoreGraphics

/// A damped spring driven frame by frame by the strip's display link.
/// Retargeting keeps velocity, so interrupted animations stay continuous.
public struct Spring: Equatable, Sendable {
    public var value: CGFloat
    public var velocity: CGFloat = 0
    public var target: CGFloat
    public var stiffness: CGFloat
    public var damping: CGFloat

    /// `response` is the period in seconds; `dampingRatio` 1 means no overshoot.
    public init(value: CGFloat, response: CGFloat = 0.28, dampingRatio: CGFloat = 0.92) {
        self.value = value
        self.target = value
        let omega = 2 * .pi / response
        self.stiffness = omega * omega
        self.damping = 2 * dampingRatio * omega
    }

    public var isSettled: Bool {
        abs(target - value) < 0.05 && abs(velocity) < 0.5
    }

    public mutating func snap() {
        value = target
        velocity = 0
    }

    public mutating func snap(to target: CGFloat) {
        self.target = target
        snap()
    }

    /// Advances by `dt` seconds with fixed substeps (stable at any frame rate).
    public mutating func step(_ dt: CGFloat) {
        guard !isSettled else {
            snap()
            return
        }
        var remaining = min(dt, 0.1)
        let substep: CGFloat = 1.0 / 480.0
        while remaining > 0 {
            let h = min(substep, remaining)
            let force = -stiffness * (value - target) - damping * velocity
            velocity += force * h
            value += velocity * h
            remaining -= h
        }
        if isSettled { snap() }
    }
}
