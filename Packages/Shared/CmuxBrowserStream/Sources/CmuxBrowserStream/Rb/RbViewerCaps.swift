public import CmuxMobileWire

/// What the viewer can decode (`cmux.rb/1` `ViewerCaps`).
public struct RbViewerCaps: Hashable, Sendable {
    public var codecs: [String]
    public var tileCodecs: [String]
    public var maxFPS: UInt32

    public init(codecs: [String] = ["h264"], tileCodecs: [String] = [], maxFPS: UInt32 = 60) {
        self.codecs = codecs
        self.tileCodecs = tileCodecs
        self.maxFPS = maxFPS
    }

    public var jsonValue: JSONValue {
        .object(["codecs": .array(codecs.map { .string($0) }), "tile_codecs": .array(tileCodecs.map { .string($0) }),
                 "max_fps": .int(Int64(maxFPS))])
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        codecs = try r.array("codecs").compactMap(\.stringValue)
        tileCodecs = try r.array("tile_codecs").compactMap(\.stringValue)
        maxFPS = try r.uint32("max_fps")
    }
}
