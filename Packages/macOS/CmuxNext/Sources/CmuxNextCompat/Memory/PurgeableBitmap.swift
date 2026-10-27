public import CoreGraphics

/// Decoded pixels in a ``PurgeableBuffer`` (32-bit BGRA, premultiplied, the layout Core Animation draws
/// without converting): Chrome's decoded images in discardable memory (`cc/tiles/software_image_decode_cache.cc`).
///
/// The pixels are copied once, when it is made; ``image()`` wraps the locked bytes in a `CGImage` without a
/// copy, and the pixels stay locked while anything holds that image (a layer that shows it, a view, a
/// decode). A cache keeps the bitmap, never an image, so its pixels are volatile whenever nothing shows them.
public struct PurgeableBitmap: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    /// The pixels' color space by name: the image's own when it is a named RGB space an 8-bit context draws in,
    /// else sRGB.
    private let colorSpaceName: String
    private let buffer: PurgeableBuffer

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// The bytes a `width` x `height` bitmap holds (rows padded to 64 bytes), before one is made: a cache asks
    /// whether a picture fits before it pays for the copy.
    ///
    /// - Parameters:
    ///   - width: Pixels across.
    ///   - height: Pixels down.
    public static func byteCount(width: Int, height: Int) -> Int {
        rowBytes(width) * max(0, height)
    }

    /// Copies `image`'s pixels into new pages from `allocator`, volatile; nil for an empty image or when the
    /// pages or the drawing context cannot be made.
    ///
    /// - Parameters:
    ///   - image: The picture.
    ///   - allocator: Makes the pages.
    public init?(_ image: CGImage, allocator: PurgeableAllocator) {
        let width = image.width, height = image.height, rowBytes = Self.rowBytes(width)
        guard width > 0, height > 0 else { return nil }
        var name = CGColorSpace.sRGB as String
        let made = PurgeableBuffer(byteCount: rowBytes * height, allocator: allocator) { base in
            for candidate in [Self.colorSpaceName(of: image), name] {
                guard let space = CGColorSpace(name: candidate as CFString),
                      // SAFETY: `base` points at `rowBytes * height` writable bytes for this call; the context draws
                      // only within them and is released before the call returns.
                      let context = unsafe CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                                     bytesPerRow: rowBytes, space: space, bitmapInfo: Self.bitmapInfo)
                else { continue }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                name = candidate
                return true
            }
            return false
        }
        guard let made else { return nil }
        self.width = width
        self.height = height
        bytesPerRow = rowBytes
        colorSpaceName = name
        buffer = made
    }

    /// The bytes it holds.
    public var byteCount: Int { buffer.byteCount }

    /// Whether the kernel took the pixels (seen at a lock).
    public var isPurged: Bool { buffer.isPurged }

    /// The pixels as an image that keeps them locked while it lives; nil when the kernel purged them (a miss:
    /// the owner drops the entry and pictures it again), never a blank image.
    public func image() -> CGImage? {
        guard let space = CGColorSpace(name: colorSpaceName as CFString), let data = buffer.lockedData(),
              let provider = CGDataProvider(data: data) else { return nil }
        // SAFETY: `decode` is nil, so Core Graphics reads no caller array; the provider owns the locked bytes.
        return unsafe CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                              space: space, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider,
                              decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Moves its locked bytes to the holding cache's `ledger` (nil when the cache drops it).
    ///
    /// - Parameter ledger: The holding cache's ledger.
    public func attach(to ledger: PurgeableLedger?) {
        buffer.attach(to: ledger)
    }

    private static func rowBytes(_ width: Int) -> Int {
        (max(0, width) * 4 + 63) & ~63
    }

    /// The image's color space name when it is a named RGB space, else sRGB's; a space an 8-bit context cannot
    /// draw in (an extended range one) falls back to sRGB when the context is made.
    private static func colorSpaceName(of image: CGImage) -> String {
        guard let space = image.colorSpace, space.model == .rgb, let name = space.name as String? else {
            return CGColorSpace.sRGB as String
        }
        return name
    }
}
