public import CoreGraphics
public import Foundation
internal import ImageIO

/// A kept picture in purgeable pages: its encoded bytes (JPEG or PNG), or its decoded pixels
/// (``PurgeableBitmap``). An encoded one's ``image()`` decodes lazily from the locked bytes, at its draw,
/// and keeps them locked while the image lives.
public struct PurgeablePicture: Sendable {
    private enum Storage: Sendable {
        case encoded(PurgeableBuffer)
        case decoded(PurgeableBitmap)
    }

    private let storage: Storage

    /// Keeps a copy of encoded `data`; nil when the pages cannot be made.
    ///
    /// - Parameters:
    ///   - data: The encoded picture (checked to open before; ``image()`` is nil when it does not).
    ///   - allocator: Makes the pages.
    public init?(encoded data: Data, allocator: PurgeableAllocator) {
        guard let buffer = PurgeableBuffer(copying: data, allocator: allocator) else { return nil }
        storage = .encoded(buffer)
    }

    /// Keeps a copy of `image`'s decoded pixels; nil when the pages cannot be made.
    ///
    /// - Parameters:
    ///   - image: The picture.
    ///   - allocator: Makes the pages.
    public init?(decoding image: CGImage, allocator: PurgeableAllocator) {
        guard let bitmap = PurgeableBitmap(image, allocator: allocator) else { return nil }
        storage = .decoded(bitmap)
    }

    /// The bytes it keeps: the encoded bytes, or the decoded pixels.
    public var byteCount: Int {
        switch storage {
        case .encoded(let buffer): buffer.byteCount
        case .decoded(let bitmap): bitmap.byteCount
        }
    }

    /// The picture, keeping its bytes locked while the image lives; nil when the kernel purged them (a miss),
    /// never a blank image. An encoded picture's image is lazy: its pixels decode where it is drawn.
    public func image() -> CGImage? {
        switch storage {
        case .decoded(let bitmap):
            return bitmap.image()
        case .encoded(let buffer):
            guard let data = buffer.lockedData(), let source = CGImageSourceCreateWithData(data, nil) else { return nil }
            // kCGImageSourceShouldCache false: only the header is read here (CheckedImageSource's lazy image).
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
    }

    /// Moves its locked bytes to the holding store's `ledger` (nil when the store drops it).
    ///
    /// - Parameter ledger: The holding store's ledger.
    public func attach(to ledger: PurgeableLedger?) {
        switch storage {
        case .encoded(let buffer): buffer.attach(to: ledger)
        case .decoded(let bitmap): bitmap.attach(to: ledger)
        }
    }
}
