public import CmuxMobileWire
public import CmuxBrowserStream

/// `channel.opened` params of an `rd` channel (c3-rd.md 2.2).
public struct RemoteDesktopChannelOpened: Hashable, Sendable {
    public static let rdDatagrams = "rd_datagrams"

    /// Where the Mac draws the pointer: `local` means the phone draws it
    /// (capture excludes the cursor); `inVideo` means it is in the pixels.
    public enum Cursor: String, Hashable, Sendable {
        case local
        case inVideo = "in_video"
    }

    public var media: String
    /// The A0 id the datagram lane's records carry (the rd channel's own).
    public var datagramChannel: UInt32
    public var encoder: BrowserVideoCodec
    public var target: DesktopTargetInfo
    public var view: DesktopView
    public var displays: [DesktopDisplay]
    public var mode: DesktopMode
    public var cursor: Cursor
    public var caps: [String]

    public init(datagramChannel: UInt32, encoder: BrowserVideoCodec = .h264, target: DesktopTargetInfo, view: DesktopView,
                displays: [DesktopDisplay], mode: DesktopMode, cursor: Cursor, caps: [String]) {
        media = Self.rdDatagrams
        self.datagramChannel = datagramChannel
        self.encoder = encoder
        self.target = target
        self.view = view
        self.displays = displays
        self.mode = mode
        self.cursor = cursor
        self.caps = caps
    }

    public var params: [String: JSONValue] {
        [
            "media": .string(media),
            "datagram_channel": .int(Int64(datagramChannel)),
            "encoder": .string(encoder.rawValue),
            "target": target.jsonValue,
            "view": view.jsonValue,
            "displays": .array(displays.map(\.jsonValue)),
            "mode": .string(mode.rawValue),
            "cursor": .string(cursor.rawValue),
            "caps": .array(caps.map { .string($0) }),
        ]
    }

    public init(params: [String: JSONValue]) throws(RdWireError) {
        let r = DesktopJSON(params)
        media = try r.string("media")
        guard media == Self.rdDatagrams else { throw RdWireError("media \(media) is not supported") }
        datagramChannel = try r.uint32("datagram_channel")
        guard let encoder = BrowserVideoCodec(rawValue: try r.string("encoder")) else { throw RdWireError("encoder") }
        self.encoder = encoder
        target = try DesktopTargetInfo(json: try r.value("target"))
        view = try DesktopView(json: try r.value("view"))
        displays = r.has("displays") ? try r.array("displays").map { (v) throws(RdWireError) in try DesktopDisplay(json: v) } : []
        guard let mode = DesktopMode(rawValue: try r.string("mode")) else { throw RdWireError("mode") }
        self.mode = mode
        cursor = Cursor(rawValue: r.optionalString("cursor") ?? "") ?? .inVideo
        caps = (try? r.array("caps"))?.compactMap(\.stringValue) ?? []
    }
}
