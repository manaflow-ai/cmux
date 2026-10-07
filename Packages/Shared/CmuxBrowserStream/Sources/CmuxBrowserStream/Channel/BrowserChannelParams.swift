public import CmuxMobileWire

/// `channel.open` params of a `browser` channel (browser.schema.json) or a
/// `simulator` channel (simulator.schema.json): the same screen, codecs and
/// lane, with the target's id.
public struct BrowserChannelParams: Hashable, Sendable {
    public var target: BrowserStreamTarget
    /// The target's id (the tab id for a browser channel).
    public var tab: String { target.id }
    public var screen: RbScreenInfo
    public var codecs: [BrowserVideoCodec]
    /// The phone will open a datagram lane for video.
    public var datagramLane: Bool

    public init(tab: String, screen: RbScreenInfo, codecs: [BrowserVideoCodec] = [.h264], datagramLane: Bool = true) {
        self.init(target: .tab(tab), screen: screen, codecs: codecs, datagramLane: datagramLane)
    }

    public init(simulator udid: String, screen: RbScreenInfo, codecs: [BrowserVideoCodec] = [.h264], datagramLane: Bool = true) {
        self.init(target: .simulator(udid), screen: screen, codecs: codecs, datagramLane: datagramLane)
    }

    public init(target: BrowserStreamTarget, screen: RbScreenInfo, codecs: [BrowserVideoCodec] = [.h264],
                datagramLane: Bool = true) {
        self.target = target
        self.screen = screen
        self.codecs = codecs
        self.datagramLane = datagramLane
    }

    public var params: [String: JSONValue] {
        [
            target.parameterName: .string(target.id),
            "service": .string(RdControlMessage.browserService),
            "screen": .object(["css_width": .int(Int64(screen.cssWidth)), "css_height": .int(Int64(screen.cssHeight)),
                               "scale": .double(screen.scale), "refresh_hz": .int(Int64(screen.refreshHz))]),
            "codecs": .array(codecs.map { .string($0.rawValue) }),
            "datagram_lane": .bool(datagramLane),
        ]
    }

    /// Decodes a `browser` channel's params.
    public init(params: [String: JSONValue]) throws(RdWireError) {
        try self.init(params: params, kind: .browser)
    }

    /// Decodes the params of a `browser` or `simulator` channel.
    public init(params: [String: JSONValue], kind: ChannelKind) throws(RdWireError) {
        let r = try RbJSONReader(.object(params))
        let target: BrowserStreamTarget
        switch kind {
        case .browser: target = .tab(try r.string("tab"))
        case .simulator: target = .simulator(try r.string("udid"))
        default: throw RdWireError("not a stream channel kind")
        }
        guard target.isValid else { throw RdWireError(target.parameterName) }
        guard try r.string("service") == RdControlMessage.browserService else { throw RdWireError("service must be rb/1") }
        let screen = try RbScreenInfo(json: try r.value("screen"))
        guard screen.cssWidth >= 1, screen.cssHeight >= 1, screen.cssWidth <= 8192, screen.cssHeight <= 8192,
              (0.5...4).contains(screen.scale) else { throw RdWireError("screen") }
        self.target = target
        self.screen = screen
        let named = (try? r.array("codecs"))?.compactMap { $0.stringValue.flatMap(BrowserVideoCodec.init(rawValue:)) }
        codecs = named?.isEmpty == false ? named! : [.h264]
        datagramLane = (try? r.bool("datagram_lane")) ?? false
    }
}
