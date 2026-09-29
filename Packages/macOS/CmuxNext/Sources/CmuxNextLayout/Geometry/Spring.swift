public import CoreGraphics

/// Spring tuning in SwiftUI terms.
public nonisolated struct SpringParameters: Hashable, Sendable {
    /// Seconds for one undamped oscillation; smaller is stiffer.
    public var response: Double
    /// 1 is critically damped; below 1 overshoots.
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// Pane and column structure changes.
    public static let layout = SpringParameters(response: 0.34, dampingFraction: 0.88)
    /// Scroll settling after a fling or keyboard focus move.
    public static let scroll = SpringParameters(response: 0.42, dampingFraction: 0.96)
    /// Screen switches.
    public static let screen = SpringParameters(response: 0.38, dampingFraction: 0.92)
    /// Drop highlight tracking the pointer.
    public static let highlight = SpringParameters(response: 0.2, dampingFraction: 0.9)
}

/// One scalar driven by a damped spring toward `target`.
public nonisolated struct SpringValue: Hashable, Sendable {
    public var value: CGFloat
    public var velocity: CGFloat = 0
    public var target: CGFloat

    public init(_ value: CGFloat) {
        self.value = value
        self.target = value
    }

    /// Advances by `dt` seconds using fixed substeps (semi-implicit Euler),
    /// which is stable for every frame rate up to 120 Hz and beyond.
    public mutating func step(_ dt: Double, parameters: SpringParameters) {
        let stiffness = pow(2 * .pi / max(parameters.response, 0.01), 2)
        let damping = 4 * .pi * parameters.dampingFraction / max(parameters.response, 0.01)
        var remaining = dt
        let maxStep = 1.0 / 480.0
        var x = Double(value)
        var v = Double(velocity)
        let t = Double(target)
        while remaining > 0 {
            let h = min(remaining, maxStep)
            let acceleration = -stiffness * (x - t) - damping * v
            v += acceleration * h
            x += v * h
            remaining -= h
        }
        value = CGFloat(x)
        velocity = CGFloat(v)
    }

    public func isSettled(epsilon: CGFloat) -> Bool {
        abs(value - target) < epsilon && abs(velocity) < epsilon * 8
    }

    /// Jumps to the target and stops.
    public mutating func snap() {
        value = target
        velocity = 0
    }

    /// Steps and snaps once settled. Returns true while still moving.
    public mutating func advance(_ dt: Double, parameters: SpringParameters, epsilon: CGFloat) -> Bool {
        guard value != target || velocity != 0 else { return false }
        step(dt, parameters: parameters)
        if isSettled(epsilon: epsilon) {
            snap()
            return false
        }
        return true
    }
}

/// A rect and opacity driven by springs.
public nonisolated struct AnimatedFrame: Hashable, Sendable {
    public var x: SpringValue
    public var y: SpringValue
    public var width: SpringValue
    public var height: SpringValue
    public var alpha: SpringValue

    public init(_ rect: CGRect, alpha: CGFloat = 1) {
        x = SpringValue(rect.minX)
        y = SpringValue(rect.minY)
        width = SpringValue(rect.width)
        height = SpringValue(rect.height)
        self.alpha = SpringValue(alpha)
    }

    public var rect: CGRect { CGRect(x: x.value, y: y.value, width: width.value, height: height.value) }
    public var targetRect: CGRect { CGRect(x: x.target, y: y.target, width: width.target, height: height.target) }

    public mutating func setTarget(_ rect: CGRect, alpha: CGFloat? = nil) {
        x.target = rect.minX
        y.target = rect.minY
        width.target = rect.width
        height.target = rect.height
        if let alpha { self.alpha.target = alpha }
    }

    public mutating func snap() {
        x.snap(); y.snap(); width.snap(); height.snap(); alpha.snap()
    }

    /// Returns true while any component is still moving.
    public mutating func advance(_ dt: Double, parameters: SpringParameters) -> Bool {
        let a = x.advance(dt, parameters: parameters, epsilon: 0.25)
        let b = y.advance(dt, parameters: parameters, epsilon: 0.25)
        let c = width.advance(dt, parameters: parameters, epsilon: 0.25)
        let d = height.advance(dt, parameters: parameters, epsilon: 0.25)
        let e = alpha.advance(dt, parameters: parameters, epsilon: 0.004)
        return a || b || c || d || e
    }
}
