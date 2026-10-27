public import AppKit

/// A layer value a ``RenderSpring`` animates: a scalar, point, size or rect.
public nonisolated protocol RenderSpringValue: Sendable {
    /// The value from its layer form (``layerValue``), or nil when it is another type.
    init?(layerValue: Any?)
    /// The value as a layer stores it (`NSNumber` or `NSValue`).
    var layerValue: Any { get }
    /// The zero offset.
    static var springZero: Self { get }
    /// `self - target`, per component.
    func springDelta(to target: Self) -> Self
    /// The largest component's magnitude.
    var springExtent: CGFloat { get }
    /// The value as a scalar, or nil when it has several components.
    var springScalar: CGFloat? { get }
}

nonisolated extension CGFloat: RenderSpringValue {
    public init?(layerValue: Any?) {
        guard let number = layerValue as? NSNumber else { return nil }
        self = CGFloat(number.doubleValue)
    }
    public var layerValue: Any { NSNumber(value: Double(self)) }
    public static var springZero: CGFloat { 0 }
    public func springDelta(to target: CGFloat) -> CGFloat { self - target }
    public var springExtent: CGFloat { abs(self) }
    public var springScalar: CGFloat? { self }
}

nonisolated extension CGPoint: RenderSpringValue {
    public init?(layerValue: Any?) {
        guard let value = layerValue as? NSValue else { return nil }
        self = value.pointValue
    }
    public var layerValue: Any { NSValue(point: self) }
    public static var springZero: CGPoint { .zero }
    public func springDelta(to target: CGPoint) -> CGPoint { CGPoint(x: x - target.x, y: y - target.y) }
    public var springExtent: CGFloat { Swift.max(abs(x), abs(y)) }
    public var springScalar: CGFloat? { nil }
}

nonisolated extension CGSize: RenderSpringValue {
    public init?(layerValue: Any?) {
        guard let value = layerValue as? NSValue else { return nil }
        self = value.sizeValue
    }
    public var layerValue: Any { NSValue(size: self) }
    public static var springZero: CGSize { .zero }
    public func springDelta(to target: CGSize) -> CGSize { CGSize(width: width - target.width, height: height - target.height) }
    public var springExtent: CGFloat { Swift.max(abs(width), abs(height)) }
    public var springScalar: CGFloat? { nil }
}

nonisolated extension CGRect: RenderSpringValue {
    public init?(layerValue: Any?) {
        guard let value = layerValue as? NSValue else { return nil }
        self = value.rectValue
    }
    public var layerValue: Any { NSValue(rect: self) }
    public static var springZero: CGRect { .zero }
    public func springDelta(to target: CGRect) -> CGRect {
        CGRect(x: origin.x - target.origin.x, y: origin.y - target.origin.y,
               width: size.width - target.size.width, height: size.height - target.size.height)
    }
    public var springExtent: CGFloat { Swift.max(abs(origin.x), abs(origin.y), abs(size.width), abs(size.height)) }
    public var springScalar: CGFloat? { nil }
}
