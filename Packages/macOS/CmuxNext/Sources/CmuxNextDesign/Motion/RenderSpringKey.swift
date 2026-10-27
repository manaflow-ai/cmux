public import QuartzCore

/// A layer property a ``RenderSpring`` moves: the Core Animation key path its additive springs
/// name, and typed reads and writes of the layer's model value. The spring never reads or writes
/// the model through key-value coding, so a key path it cannot type is a compile error, not a
/// runtime lookup (plans/cmux-next/crash-elimination.md, class dynamic_dispatch).
public struct RenderSpringKey<Value: RenderSpringValue> {
    /// The key path the springs animate (`position.x`, `bounds.size`).
    public let path: String
    private let read: (CALayer) -> Value?
    private let write: (CALayer, Value) -> Void

    /// A key whose model value `read` returns (nil when the layer's value is not a `Value`) and
    /// `write` sets; both act on the property `path` names.
    public init(_ path: String, read: @escaping (CALayer) -> Value?, write: @escaping (CALayer, Value) -> Void) {
        self.path = path
        self.read = read
        self.write = write
    }

    /// `layer`'s model value of this key, or nil when it is not a `Value`.
    public func value(of layer: CALayer) -> Value? {
        read(layer)
    }

    /// Sets `layer`'s model value of this key to `value` (actions as the caller's transaction has them).
    public func set(_ value: Value, on layer: CALayer) {
        write(layer, value)
    }
}

extension RenderSpringKey where Value == CGFloat {
    public static var positionX: Self { Self("position.x", read: { $0.position.x }, write: { $0.position.x = $1 }) }
    public static var positionY: Self { Self("position.y", read: { $0.position.y }, write: { $0.position.y = $1 }) }
    public static var boundsOriginX: Self {
        Self("bounds.origin.x", read: { $0.bounds.origin.x }, write: { $0.bounds.origin.x = $1 })
    }
    public static var boundsOriginY: Self {
        Self("bounds.origin.y", read: { $0.bounds.origin.y }, write: { $0.bounds.origin.y = $1 })
    }
    public static var boundsWidth: Self {
        Self("bounds.size.width", read: { $0.bounds.size.width }, write: { $0.bounds.size.width = $1 })
    }
    public static var boundsHeight: Self {
        Self("bounds.size.height", read: { $0.bounds.size.height }, write: { $0.bounds.size.height = $1 })
    }
    public static var cornerRadius: Self { Self("cornerRadius", read: { $0.cornerRadius }, write: { $0.cornerRadius = $1 }) }
    /// The layer's `opacity` (a `Float`) as a scalar.
    public static var opacity: Self { Self("opacity", read: { CGFloat($0.opacity) }, write: { $0.opacity = Float($1) }) }
    /// The layer's `shadowOpacity` (a `Float`) as a scalar: the strength only; the shape stays the
    /// layer's shadowPath (``CALayer/cast(shadowPath:)``).
    public static var shadowOpacity: Self {
        Self("shadowOpacity", read: { CGFloat($0.shadowOpacity) }, write: { $0.shadowOpacity = Float($1) })
    }
    /// The x translation of the layer's `transform` (its `m41`).
    public static var translationX: Self {
        Self("transform.translation.x", read: { $0.transform.m41 }, write: { $0.transform.m41 = $1 })
    }
    /// The y translation of the layer's `transform` (its `m42`).
    public static var translationY: Self {
        Self("transform.translation.y", read: { $0.transform.m42 }, write: { $0.transform.m42 = $1 })
    }
    /// The x translation of the layer's `sublayerTransform` (its `m41`).
    public static var sublayerTranslationX: Self {
        Self("sublayerTransform.translation.x", read: { $0.sublayerTransform.m41 }, write: { $0.sublayerTransform.m41 = $1 })
    }
    /// The y translation of the layer's `sublayerTransform` (its `m42`).
    public static var sublayerTranslationY: Self {
        Self("sublayerTransform.translation.y", read: { $0.sublayerTransform.m42 }, write: { $0.sublayerTransform.m42 = $1 })
    }
}

extension RenderSpringKey where Value == CGPoint {
    public static var position: Self { Self("position", read: { $0.position }, write: { $0.position = $1 }) }
    public static var boundsOrigin: Self { Self("bounds.origin", read: { $0.bounds.origin }, write: { $0.bounds.origin = $1 }) }
}

extension RenderSpringKey where Value == CGSize {
    public static var boundsSize: Self { Self("bounds.size", read: { $0.bounds.size }, write: { $0.bounds.size = $1 }) }
}

extension RenderSpringKey where Value == CGRect {
    public static var bounds: Self { Self("bounds", read: { $0.bounds }, write: { $0.bounds = $1 }) }
}
