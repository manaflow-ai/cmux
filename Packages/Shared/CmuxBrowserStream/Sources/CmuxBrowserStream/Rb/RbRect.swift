import CmuxMobileWire

/// A rectangle in the surface's CSS pixels.
public struct RbRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var jsonValue: JSONValue {
        .object(["x": .double(x), "y": .double(y), "width": .double(width), "height": .double(height)])
    }

    init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        x = try r.double("x")
        y = try r.double("y")
        width = try r.double("width")
        height = try r.double("height")
    }
}
