public import CoreGraphics

/// A bitmap that Core Graphics draws into and Swift owns: the context draws
/// into an array, and the pixels are read from ``bytes`` with checked indexes,
/// never through `CGContext.data`. Chromium does the same with SkBitmap,
/// which owns its pixels and gives readers a bounded view
/// (third_party/skia/include/core/SkBitmap.h).
public nonisolated struct DrawnPixels: Sendable {
    public let width: Int
    public let height: Int
    /// Bytes per pixel: 1 for a gray or alpha-only bitmap, 4 for RGBA.
    public let bytesPerPixel: Int
    /// The pixels, row 0 first (the top of the drawing), `width * bytesPerPixel` bytes per row.
    public let bytes: [UInt8]

    /// Draws `body` into a `width` x `height` bitmap of `bytesPerPixel`-byte
    /// pixels (8 bits per component) in `space`, starting all zero. Nil when
    /// a side is not positive or Core Graphics cannot make the context. The
    /// context is valid only inside `body`; do not keep it.
    public init?(width: Int, height: Int, bytesPerPixel: Int, space: CGColorSpace, bitmapInfo: UInt32,
                 draw body: (CGContext) -> Void) {
        guard width > 0, height > 0, bytesPerPixel > 0 else { return nil }
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        // SAFETY: the context writes into `buffer`, the array's own bytesPerRow * height bytes, which stay valid for
        // the closure; the context is used only inside it (`body` is told not to keep it).
        let drawn = unsafe bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = unsafe CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo) else { return false }
            body(context)
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytesPerPixel = bytesPerPixel
        self.bytes = bytes
    }

    /// Byte `channel` of the pixel at (`x`, `y`), row 0 the top.
    public subscript(x: Int, y: Int, channel: Int) -> UInt8 {
        bytes[(y * width + x) * bytesPerPixel + channel]
    }
}
