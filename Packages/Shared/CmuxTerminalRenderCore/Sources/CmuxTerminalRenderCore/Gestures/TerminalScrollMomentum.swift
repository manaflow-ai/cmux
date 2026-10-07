import Foundation

/// Deceleration after a one-finger scroll ends, stepped by the gesture
/// display link: velocity decays exponentially (UIScrollView's normal rate)
/// until it falls under the stop speed, then the link stops.
public struct TerminalScrollMomentum: Hashable, Sendable {
    /// Points per second.
    public private(set) var velocity: Double
    /// Fraction of velocity kept per millisecond (UIScrollView.DecelerationRate.normal).
    public let decelerationRate: Double
    /// Below this speed (points per second) the motion ends.
    public let stopSpeed: Double

    public init(velocity: Double, decelerationRate: Double = 0.998, stopSpeed: Double = 20) {
        self.velocity = velocity.isFinite ? velocity : 0
        self.decelerationRate = min(max(decelerationRate, 0), 0.9999)
        self.stopSpeed = stopSpeed
    }

    public var isFinished: Bool { abs(velocity) < stopSpeed }

    /// Advances by `dt` seconds; returns the distance moved in points.
    public mutating func step(_ dt: Double) -> Double {
        guard !isFinished, dt > 0, dt.isFinite else { return 0 }
        let milliseconds = dt * 1000
        let decay = pow(decelerationRate, milliseconds)
        // Integral of v0 * r^t over the step, t in ms.
        let lnRate = log(decelerationRate)
        let distance = velocity * (decay - 1) / lnRate / 1000
        velocity *= decay
        if isFinished { velocity = 0 }
        return distance
    }
}
