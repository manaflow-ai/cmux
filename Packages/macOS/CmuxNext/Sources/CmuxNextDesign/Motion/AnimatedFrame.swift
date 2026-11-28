public import CoreGraphics

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

    /// Returns true while any component is still moving. `alphaParameters`
    /// defaults to the geometry spring.
    public mutating func advance(_ dt: Double, parameters: SpringParameters, alphaParameters: SpringParameters? = nil) -> Bool {
        let a = x.advance(dt, parameters: parameters, epsilon: 0.25)
        let b = y.advance(dt, parameters: parameters, epsilon: 0.25)
        let c = width.advance(dt, parameters: parameters, epsilon: 0.25)
        let d = height.advance(dt, parameters: parameters, epsilon: 0.25)
        let e = alpha.advance(dt, parameters: alphaParameters ?? parameters, epsilon: 0.004)
        return a || b || c || d || e
    }
}
