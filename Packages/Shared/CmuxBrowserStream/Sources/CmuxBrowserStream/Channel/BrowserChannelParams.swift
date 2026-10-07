public import CmuxMobileWire

/// `channel.open` params of a `browser` channel (browser.schema.json).
public struct BrowserChannelParams: Hashable, Sendable {
    public var tab: String
    public var screen: RbScreenInfo
    public var codecs: [BrowserVideoCodec]
    /// The phone will open a datagram lane for video.
    public var datagramLane: Bool

    public init(tab: String, screen: RbScreenInfo, codecs: [BrowserVideoCodec] = [.h264], datagramLane: Bool = true) {
        self.tab = tab
        self.screen = screen
        self.codecs = codecs
        self.datagramLane = datagramLane
    }

    public var params: [String: JSONValue] {
        [
            "tab": .string(tab),
            "service": .string(RdControlMessage.browserService),
            "screen": .object(["css_width": .int(Int64(screen.cssWidth)), "css_height": .int(Int64(screen.cssHeight)),
                               "scale": .double(screen.scale), "refresh_hz": .int(Int64(screen.refreshHz))]),
            "codecs": .array(codecs.map { .string($0.rawValue) }),
            "datagram_lane": .bool(datagramLane),
        ]
    }

    public init(params: [String: JSONValue]) throws(RdWireError) {
        let r = try RbJSONReader(.object(params))
        let tab = try r.string("tab")
        guard tab.hasPrefix("tab_"), tab.count <= 128 else { throw RdWireError("tab") }
        guard try r.string("service") == RdControlMessage.browserService else { throw RdWireError("service must be rb/1") }
        let screen = try RbScreenInfo(json: try r.value("screen"))
        guard screen.cssWidth >= 1, screen.cssHeight >= 1, screen.cssWidth <= 8192, screen.cssHeight <= 8192,
              (0.5...4).contains(screen.scale) else { throw RdWireError("screen") }
        self.tab = tab
        self.screen = screen
        let named = (try? r.array("codecs"))?.compactMap { $0.stringValue.flatMap(BrowserVideoCodec.init(rawValue:)) }
        codecs = named?.isEmpty == false ? named! : [.h264]
        datagramLane = (try? r.bool("datagram_lane")) ?? false
    }
}
