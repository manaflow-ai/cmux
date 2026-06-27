public import Foundation

extension CGRect {
    /// The rectangle flattened to a `{"x","y","width","height"}` dictionary of
    /// `Double`s for the `debug.terminals` control-socket payload, where every
    /// frame/bounds field is serialized in this exact shape.
    public var controlDebugRectPayload: [String: Double] {
        [
            "x": Double(origin.x),
            "y": Double(origin.y),
            "width": Double(size.width),
            "height": Double(size.height)
        ]
    }
}
