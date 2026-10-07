public import CmuxMobileWire
import CmuxBrowserStream

/// One of the Mac's displays (`channel.opened.displays`).
public struct DesktopDisplay: Hashable, Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    /// Native pixels.
    public var width: Int
    public var height: Int
    public var scale: Double
    public var isMain: Bool

    public init(id: UInt32, name: String, width: Int, height: Int, scale: Double, isMain: Bool) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.scale = scale
        self.isMain = isMain
    }

    public var jsonValue: JSONValue {
        .object(["id": .int(Int64(id)), "name": .string(name), "width": .int(Int64(width)), "height": .int(Int64(height)),
                 "scale": .double(scale), "main": .bool(isMain)])
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try DesktopJSON(json)
        let limit = Int64(DesktopViewFit.maxTargetSide)
        id = try r.uint32("id")
        name = try r.string("name")
        width = try r.int("width", in: 0...limit)
        height = try r.int("height", in: 0...limit)
        scale = try r.double("scale")
        isMain = try r.bool("main")
    }
}
