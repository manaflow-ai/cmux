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

    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// The 16 wire bytes.
    public var encoded: [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0,
         UInt8(redMax >> 8), UInt8(redMax & 0xFF), UInt8(greenMax >> 8), UInt8(greenMax & 0xFF),
         UInt8(blueMax >> 8), UInt8(blueMax & 0xFF), redShift, greenShift, blueShift, 0, 0, 0]
    }

    /// Parses 16 wire bytes; nil when short.
    public init?(bytes: some Collection<UInt8>) {
        let b = Array(bytes)
        guard b.count >= 16 else { return nil }
        self.init(bitsPerPixel: b[0], depth: b[1], bigEndian: b[2] != 0, trueColor: b[3] != 0,
                  redMax: UInt16(b[4]) << 8 | UInt16(b[5]), greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
                  blueMax: UInt16(b[8]) << 8 | UInt16(b[9]), redShift: b[10], greenShift: b[11], blueShift: b[12])
    }
}
