public import CmuxMobileWire
import CmuxBrowserStream

/// The phone viewport in backing pixels.
public struct DesktopScreen: Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public var jsonValue: JSONValue {
        .object(["pixel_width": .int(Int64(pixelWidth)), "pixel_height": .int(Int64(pixelHeight)), "scale": .double(scale)])
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try DesktopJSON(json)
        pixelWidth = try r.int("pixel_width", in: 16...8192)
        pixelHeight = try r.int("pixel_height", in: 16...8192)
        scale = try r.double("scale")
        guard (0.5...4).contains(scale) else { throw RdWireError("screen scale") }
    }
}
