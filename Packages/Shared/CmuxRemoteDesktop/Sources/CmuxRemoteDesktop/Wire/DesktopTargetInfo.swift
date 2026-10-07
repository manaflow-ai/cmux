public import CmuxMobileWire
import CmuxBrowserStream

/// The target as the Mac sees it: its full size in target pixels (input
/// coordinates are in this space), its backing scale and a label.
public struct DesktopTargetInfo: Hashable, Sendable {
    public var kind: DesktopTargetKind
    public var width: Int
    public var height: Int
    public var scale: Double
    public var name: String

    public init(kind: DesktopTargetKind, width: Int, height: Int, scale: Double, name: String) {
        self.kind = kind
        self.width = width
        self.height = height
        self.scale = scale
        self.name = name
    }

    public var bounds: DesktopRect { DesktopRect(width: width, height: height) }

    var jsonMembers: [String: JSONValue] {
        ["kind": .string(kind.rawValue), "width": .int(Int64(width)), "height": .int(Int64(height)),
         "scale": .double(scale), "name": .string(name)]
    }

    public var jsonValue: JSONValue { .object(jsonMembers) }

    public init(json: JSONValue) throws(RdWireError) {
        try self.init(reader: DesktopJSON(json))
    }

    init(reader r: DesktopJSON) throws(RdWireError) {
        guard let kind = DesktopTargetKind(rawValue: try r.string("kind")) else { throw RdWireError("target kind") }
        let limit = Int64(DesktopViewFit.maxTargetSide)
        self.kind = kind
        width = try r.int("width", in: 0...limit)
        height = try r.int("height", in: 0...limit)
        scale = try r.double("scale")
        name = try r.string("name")
    }
}
