import Foundation

/// An RFB `PIXEL_FORMAT` (RFC 6143 §7.4). Sixteen bytes on the wire.
///
/// cmux always negotiates a fixed 32-bit little-endian true-colour format so
/// the decoded framebuffer maps 1:1 onto a `CGImage` with no per-pixel
/// swizzling. The server's native format (parsed from `ServerInit`) is kept
/// only for completeness; we override it immediately with `SetPixelFormat`.
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

    public init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndian: Bool,
        trueColor: Bool,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
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

    /// Bytes per pixel for the negotiated format.
    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// The fixed format cmux requests: 32 bpp, depth 24, little-endian,
    /// true-colour, channels at shifts B=0, G=8, R=16. In a little-endian
    /// `UInt32` a pixel reads `0x00RRGGBB`; in memory the bytes are `B G R X`,
    /// which is exactly Core Graphics' `BGRX` (`noneSkipFirst` +
    /// `byteOrder32Little`). This keeps the render path allocation- and
    /// swizzle-free.
    public static let cmuxBGRX = RFBPixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    /// Serialises the 16-byte wire representation.
    public func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        bytes.append(bitsPerPixel)
        bytes.append(depth)
        bytes.append(bigEndian ? 1 : 0)
        bytes.append(trueColor ? 1 : 0)
        bytes.append(UInt8(redMax >> 8)); bytes.append(UInt8(redMax & 0xFF))
        bytes.append(UInt8(greenMax >> 8)); bytes.append(UInt8(greenMax & 0xFF))
        bytes.append(UInt8(blueMax >> 8)); bytes.append(UInt8(blueMax & 0xFF))
        bytes.append(redShift)
        bytes.append(greenShift)
        bytes.append(blueShift)
        bytes.append(contentsOf: [0, 0, 0]) // padding
        return bytes
    }

    /// Parses a 16-byte wire representation. Returns `nil` if short.
    public init?(_ bytes: ArraySlice<UInt8>) {
        guard bytes.count >= 16 else { return nil }
        let b = Array(bytes)
        self.init(
            bitsPerPixel: b[0],
            depth: b[1],
            bigEndian: b[2] != 0,
            trueColor: b[3] != 0,
            redMax: (UInt16(b[4]) << 8) | UInt16(b[5]),
            greenMax: (UInt16(b[6]) << 8) | UInt16(b[7]),
            blueMax: (UInt16(b[8]) << 8) | UInt16(b[9]),
            redShift: b[10],
            greenShift: b[11],
            blueShift: b[12]
        )
    }
}
