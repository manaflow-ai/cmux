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

    /// Advances the rect without letting it settle on its own; the alpha settles as in
    /// ``advance(_:parameters:alphaParameters:)``. For several frames that move as one motion (the
    /// panes and dividers of a split or a close): each edge would otherwise snap in its own frame,
    /// so edges with different travels land frames apart and a gap between them changes by up to
    /// the snap distance. The caller lands them together once ``geometryNearRest`` holds for all.
    ///
    /// - Parameters:
    ///   - dt: Seconds since the previous frame.
    ///   - parameters: The rect's spring.
    ///   - alphaParameters: The alpha's spring; defaults to `parameters`.
    /// - Returns: Whether the alpha still moves.
    public mutating func advanceUnsettled(_ dt: Double, parameters: SpringParameters, alphaParameters: SpringParameters? = nil) -> Bool {
        _ = x.advance(dt, parameters: parameters, epsilon: 0)
        _ = y.advance(dt, parameters: parameters, epsilon: 0)
        _ = width.advance(dt, parameters: parameters, epsilon: 0)
        _ = height.advance(dt, parameters: parameters, epsilon: 0)
        return alpha.advance(dt, parameters: alphaParameters ?? parameters, epsilon: 0.004)
    }

    /// The rect is within a quarter point of its target on every edge and slower than 2 pt/s: where
    /// ``advance(_:parameters:alphaParameters:)`` would snap it.
    public var geometryNearRest: Bool {
        [x, y, width, height].allSatisfy { abs($0.value - $0.target) <= 0.25 && abs($0.velocity) <= 2 }
    }

    /// Puts the rect on its target at rest; the alpha keeps moving.
    public mutating func snapGeometry() {
        x.snap(); y.snap(); width.snap(); height.snap()
    }
}
