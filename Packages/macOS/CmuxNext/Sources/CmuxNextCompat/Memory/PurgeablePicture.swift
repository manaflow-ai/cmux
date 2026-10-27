public import CoreGraphics
public import Foundation
internal import ImageIO

/// A kept picture: its encoded bytes (JPEG or PNG) or its decoded pixels (``PurgeableBitmap``) in purgeable
/// pages, or, with a ``PurgeableAllocator/resident`` allocator (feature `purgeableImageCaches` off), the decoded
/// image itself, as the caches kept it before (no copy, no color conversion). An encoded one's ``image()``
/// decodes lazily from the locked bytes, at its draw, and keeps them locked while the image lives.
public struct PurgeablePicture: Sendable {
    private enum Storage: Sendable {
        case encoded(PurgeableBuffer)
        case decoded(PurgeableBitmap)
        case resident(ResidentImage)
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

    /// Keeps `image` itself: no copy and no color conversion; never purged, so it always counts in the footprint.
    ///
    /// - Parameter image: The picture.
    public init(resident image: CGImage) {
        storage = .resident(ResidentImage(image))
    }

    /// Keeps a copy of `image`'s decoded pixels in pages from `allocator`, whatever the allocator, drawn on the
    /// calling thread; nil when the pages cannot be made. A store makes its pictures with ``keeping(_:allocator:)``.
    ///
    /// - Parameters:
    ///   - image: The picture.
    ///   - allocator: Makes the pages.
    public init?(decoding image: CGImage, allocator: PurgeableAllocator) {
        guard let bitmap = PurgeableBitmap(image, allocator: allocator) else { return nil }
        storage = .decoded(bitmap)
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    /// `image` as a store keeps it: with a resident allocator the image itself, at once (``init(resident:)``);
    /// else a copy of its decoded pixels in new pages from `allocator`, drawn off the caller's actor, so the
    /// full-picture draw never runs on the main actor. Nil when the pages cannot be made.
    ///
    /// - Parameters:
    ///   - image: The picture.
    ///   - allocator: Makes the pages.
    public static func keeping(_ image: CGImage, allocator: PurgeableAllocator) async -> PurgeablePicture? {
        if allocator.isResident { return PurgeablePicture(resident: image) }
        return await copied(image, allocator: allocator)
    }

    /// The bytes ``keeping(_:allocator:)`` keeps for `image`, known before any copy: a store asks whether the
    /// picture fits before it pays for the copy.
    ///
    /// - Parameters:
    ///   - image: The picture.
    ///   - allocator: The pages it would go in.
    public static func byteCount(keeping image: CGImage, allocator: PurgeableAllocator) -> Int {
        allocator.isResident
            ? ResidentImage.byteCount(of: image) : PurgeableBitmap.byteCount(width: image.width, height: image.height)
    }

    @concurrent private static func copied(_ image: CGImage, allocator: PurgeableAllocator) async -> PurgeablePicture? {
        guard let bitmap = PurgeableBitmap(image, allocator: allocator) else { return nil }
        return PurgeablePicture(storage: .decoded(bitmap))
    }

    /// The bytes it keeps: the encoded bytes, or the decoded pixels.
    public var byteCount: Int {
        switch storage {
        case .encoded(let buffer): buffer.byteCount
        case .decoded(let bitmap): bitmap.byteCount
        case .resident(let kept): kept.byteCount
        }
    }

    /// The picture, keeping its bytes locked while the image lives; nil when the kernel purged them (a miss),
    /// never a blank image. An encoded picture's image is lazy: its pixels decode where it is drawn. A resident
    /// one is the image it was made from.
    public func image() -> CGImage? {
        switch storage {
        case .decoded(let bitmap):
            return bitmap.image()
        case .encoded(let buffer):
            guard let data = buffer.lockedData(), let source = CGImageSourceCreateWithData(data, nil) else { return nil }
            // kCGImageSourceShouldCache false: only the header is read here (CheckedImageSource's lazy image).
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        case .resident(let kept):
            return kept.image
        }
    }

    /// Moves its locked bytes to the holding store's `ledger` (nil when the store drops it).
    ///
    /// - Parameter ledger: The holding store's ledger.
    public func attach(to ledger: PurgeableLedger?) {
        switch storage {
        case .encoded(let buffer): buffer.attach(to: ledger)
        case .decoded(let bitmap): bitmap.attach(to: ledger)
        case .resident(let kept): kept.attach(to: ledger)
        }
    }
}

/// A picture kept as the image itself (``PurgeablePicture/init(resident:)``): its bytes always count as locked
/// in the holding store's ledger, as ``ResidentPages`` do.
private final class ResidentImage: Sendable {
    let image: CGImage
    let byteCount: Int
    /// The holding store's ledger; nil while no store holds it.
    private let holder = Mutex<PurgeableLedger?>(nil)

    init(_ image: CGImage) {
        self.image = image
        byteCount = Self.byteCount(of: image)
    }

    /// The decoded bytes `image` takes: its rows, at least 4 bytes a pixel.
    static func byteCount(of image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, image.width * image.height * 4)
    }

    func attach(to ledger: PurgeableLedger?) {
        holder.withLock { held in
            guard held !== ledger else { return }
            held?.subtract(byteCount)
            ledger?.add(byteCount)
            held = ledger
        }
    }
}
