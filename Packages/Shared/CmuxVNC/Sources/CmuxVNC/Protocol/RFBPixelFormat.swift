import Foundation

/// An RFB `PIXEL_FORMAT` (RFC 6143 section 7.4), sixteen bytes on the wire.
///
/// The client always asks for 32-bit little-endian true colour with red at
/// shift 16, green 8, blue 0: in memory a pixel is `B G R X`, which is
/// `kCVPixelFormatType_32BGRA` and Core Graphics' little-endian `noneSkipFirst`,
/// so decoded rectangles copy straight into an IOSurface.
public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColor: Bool,
                redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
                redShift: UInt8, greenShift: UInt8, blueShift: UInt8) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// The format this client requests (see the type comment).
    public static let bgrx = RFBPixelFormat(
        bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
        redMax: 255, greenMax: 255, blueMax: 255, redShift: 16, greenShift: 8, blueShift: 0)

    public var bytesPerPixel: Int { bitsPerPixel.widened / 8 }

    /// The 16 wire bytes.
    public var encoded: [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0]
            + Self.wire(redMax) + Self.wire(greenMax) + Self.wire(blueMax)
            + [redShift, greenShift, blueShift, 0, 0, 0]
    }

    /// Parses 16 wire bytes; nil when short.
    public init?(bytes: some Collection<UInt8>) {
        let b = Array(bytes.prefix(16))
        guard b.count == 16 else { return nil }
        func byte(_ at: Int) -> UInt8 { b.dropFirst(at).first ?? 0 }
        func u16(_ at: Int) -> UInt16 { b.dropFirst(at).prefix(2).bigEndian(as: UInt16.self) }
        self.init(bitsPerPixel: byte(0), depth: byte(1), bigEndian: byte(2) != 0, trueColor: byte(3) != 0,
                  redMax: u16(4), greenMax: u16(6), blueMax: u16(8),
                  redShift: byte(10), greenShift: byte(11), blueShift: byte(12))
    }

    private static func wire(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}
