import Foundation

/// The header of one rectangle inside a `FramebufferUpdate` (RFC 6143 §7.6.1).
public struct RFBRectangleHeader: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var encoding: Int32

    public init(x: Int, y: Int, width: Int, height: Int, encoding: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.encoding = encoding
    }
}

extension RFBByteSource {
    /// Reads one rectangle header (12 bytes).
    func readRectangleHeader() async throws -> RFBRectangleHeader {
        let x = try await readUInt16()
        let y = try await readUInt16()
        let w = try await readUInt16()
        let h = try await readUInt16()
        let encoding = try await readInt32()
        return RFBRectangleHeader(x: Int(x), y: Int(y), width: Int(w), height: Int(h), encoding: encoding)
    }

    /// Reads a single 32-bit BGRX pixel (little-endian, matching the format
    /// cmux negotiates). Returns a host `UInt32` of `0x00RRGGBB`.
    func readPixel() async throws -> UInt32 {
        let b = try await readExactly(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    /// Reads `count` packed BGRX pixels in a single bulk read.
    func readPixels(count: Int) async throws -> [UInt32] {
        guard count > 0 else { return [] }
        let bytes = try await readExactly(count * 4)
        var pixels = [UInt32](repeating: 0, count: count)
        bytes.withUnsafeBufferPointer { src in
            for i in 0 ..< count {
                let o = i * 4
                pixels[i] = UInt32(src[o]) | (UInt32(src[o + 1]) << 8)
                    | (UInt32(src[o + 2]) << 16) | (UInt32(src[o + 3]) << 24)
            }
        }
        return pixels
    }
}
