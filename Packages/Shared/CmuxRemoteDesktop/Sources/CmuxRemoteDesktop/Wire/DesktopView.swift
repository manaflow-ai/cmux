public import CmuxMobileWire
import CmuxBrowserStream

/// What the video shows: a rectangle of the target encoded at a pixel size.
/// `seq` names the view: the phone's requests count up from 1, and views
/// the Mac starts itself (a VNC resize, a display switch) set the top bit.
/// The Mac labels each video datagram's rd `stream` with `stream`, so the
/// phone maps a frame through the right view even when it races the
/// `view_applied` answer.
public struct DesktopView: Hashable, Sendable {
    public var seq: UInt32
    public var rect: DesktopRect
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(seq: UInt32, rect: DesktopRect, pixelWidth: Int, pixelHeight: Int) {
        self.seq = seq
        self.rect = rect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// First seq of views the Mac starts itself.
    public static let hostSeqBase: UInt32 = 0x8000_0000

    /// The rd datagram `stream` that carries frames of this view: the low 15
    /// bits of `seq`, with bit 15 set for views the Mac started.
    public var stream: UInt16 {
        UInt16(truncatingIfNeeded: seq & 0x7fff) | (seq >= Self.hostSeqBase ? 0x8000 : 0)
    }

    public var jsonMembers: [String: JSONValue] {
        var out = rect.jsonMembers
        out["seq"] = .int(Int64(seq))
        out["pixel_width"] = .int(Int64(pixelWidth))
        out["pixel_height"] = .int(Int64(pixelHeight))
        return out
    }

    public var jsonValue: JSONValue { .object(jsonMembers) }

    public init(json: JSONValue) throws(RdWireError) {
        try self.init(reader: DesktopJSON(json))
    }

    init(reader r: DesktopJSON) throws(RdWireError) {
        let limit = Int64(DesktopViewFit.maxTargetSide)
        seq = try r.uint32("seq")
        rect = DesktopRect(x: try r.int("x", in: -limit...limit), y: try r.int("y", in: -limit...limit),
                           width: try r.int("width", in: 0...limit), height: try r.int("height", in: 0...limit))
        pixelWidth = try r.int("pixel_width", in: 0...limit)
        pixelHeight = try r.int("pixel_height", in: 0...limit)
    }
}
