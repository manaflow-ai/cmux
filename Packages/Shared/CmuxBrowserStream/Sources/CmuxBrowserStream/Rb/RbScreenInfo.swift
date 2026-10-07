public import CmuxMobileWire

/// The viewer pane and its screen (`cmux.rb/1` `ScreenInfo`).
public struct RbScreenInfo: Hashable, Sendable {
    /// Pane size in CSS pixels (points on iOS).
    public var cssWidth: UInt32
    public var cssHeight: UInt32
    /// Backing scale (3 on most iPhones).
    public var scale: Double
    public var refreshHz: UInt32
    public var colorSpace: String

    public init(cssWidth: UInt32, cssHeight: UInt32, scale: Double, refreshHz: UInt32 = 60, colorSpace: String = "srgb") {
        self.cssWidth = cssWidth
        self.cssHeight = cssHeight
        self.scale = scale
        self.refreshHz = refreshHz
        self.colorSpace = colorSpace
    }

    public var jsonValue: JSONValue {
        .object(["css_width": .int(Int64(cssWidth)), "css_height": .int(Int64(cssHeight)), "scale": .double(scale),
                 "refresh_hz": .int(Int64(refreshHz)), "color_space": .string(colorSpace)])
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        cssWidth = try r.uint32("css_width")
        cssHeight = try r.uint32("css_height")
        scale = try r.double("scale")
        refreshHz = (try? r.uint32("refresh_hz")) ?? 60
        colorSpace = r.optionalString("color_space") ?? "srgb"
    }
}
