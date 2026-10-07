public import CmuxMobileWire
public import CmuxBrowserStream

/// `channel.open` params of an `rd` channel (rd.schema.json, c3-rd.md 2.1).
public struct RemoteDesktopChannelParams: Hashable, Sendable {
    public static let service = "desktop"

    public var target: DesktopTarget
    public var mode: DesktopMode
    public var screen: DesktopScreen
    public var codecs: [BrowserVideoCodec]
    /// The phone will open a datagram lane for video.
    public var datagramLane: Bool

    public init(target: DesktopTarget, mode: DesktopMode, screen: DesktopScreen, codecs: [BrowserVideoCodec] = [.h264],
                datagramLane: Bool = true) {
        self.target = target
        self.mode = mode
        self.screen = screen
        self.codecs = codecs
        self.datagramLane = datagramLane
    }

    public var params: [String: JSONValue] {
        [
            "service": .string(Self.service),
            "target": target.jsonValue,
            "mode": .string(mode.rawValue),
            "screen": screen.jsonValue,
            "codecs": .array(codecs.map { .string($0.rawValue) }),
            "datagram_lane": .bool(datagramLane),
        ]
    }

    /// Accepts the A0 0.x shorthand `{service, display}` as a main-or-numbered
    /// display target in view mode at a default phone size.
    public init(params: [String: JSONValue]) throws(RdWireError) {
        let r = DesktopJSON(params)
        guard try r.string("service") == Self.service else { throw RdWireError("service must be desktop") }
        if r.has("target") {
            target = try DesktopTarget(json: try r.value("target"))
        } else {
            target = .display(r.has("display") ? try r.uint32("display") : nil)
        }
        if r.has("mode") {
            guard let mode = DesktopMode(rawValue: try r.string("mode")) else { throw RdWireError("mode") }
            self.mode = mode
        } else {
            mode = .view
        }
        screen = r.has("screen") ? try DesktopScreen(json: try r.value("screen"))
            : DesktopScreen(pixelWidth: 1179, pixelHeight: 2556, scale: 3)
        let named = (try? r.array("codecs"))?.compactMap { $0.stringValue.flatMap(BrowserVideoCodec.init(rawValue:)) }
        codecs = named?.isEmpty == false ? named! : [.h264]
        datagramLane = (try? r.bool("datagram_lane")) ?? false
    }
}
