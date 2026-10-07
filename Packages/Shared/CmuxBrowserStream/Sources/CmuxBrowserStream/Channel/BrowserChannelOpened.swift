public import CmuxMobileWire

/// `channel.opened` params of a `browser` channel.
public struct BrowserChannelOpened: Hashable, Sendable {
    /// Always `rd_datagrams` from this host (c2-browser-stream.md section 1).
    public var media: String
    /// The A0 id the datagram lane's records carry (the browser channel's own).
    public var datagramChannel: UInt32
    public var encoder: BrowserVideoCodec
    /// Encode size in pixels.
    public var width: UInt32
    public var height: UInt32
    /// The Mac page viewport in CSS pixels.
    public var pageWidth: Double
    public var pageHeight: Double
    /// rb caps this host serves (`navigate`, `clipboard`).
    public var caps: [String]

    public static let rdDatagrams = "rd_datagrams"

    public init(datagramChannel: UInt32, encoder: BrowserVideoCodec, width: UInt32, height: UInt32,
                pageWidth: Double, pageHeight: Double, caps: [String]) {
        media = Self.rdDatagrams
        self.datagramChannel = datagramChannel
        self.encoder = encoder
        self.width = width
        self.height = height
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.caps = caps
    }

    public var params: [String: JSONValue] {
        [
            "media": .string(media),
            "datagram_channel": .int(Int64(datagramChannel)),
            "encoder": .string(encoder.rawValue),
            "width": .int(Int64(width)),
            "height": .int(Int64(height)),
            "page": .object(["css_width": .double(pageWidth), "css_height": .double(pageHeight)]),
            "caps": .array(caps.map { .string($0) }),
        ]
    }

    public init(params: [String: JSONValue]) throws(RdWireError) {
        let r = try RbJSONReader(.object(params))
        media = try r.string("media")
        datagramChannel = try r.uint32("datagram_channel")
        guard let encoder = BrowserVideoCodec(rawValue: try r.string("encoder")) else { throw RdWireError("encoder") }
        self.encoder = encoder
        width = try r.uint32("width")
        height = try r.uint32("height")
        let page = try RbJSONReader(try r.value("page"))
        pageWidth = try page.double("css_width")
        pageHeight = try page.double("css_height")
        caps = try r.array("caps").compactMap(\.stringValue)
    }
}
