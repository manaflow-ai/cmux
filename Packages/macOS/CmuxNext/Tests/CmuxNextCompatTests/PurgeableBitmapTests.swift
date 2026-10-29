import CmuxNextCompat
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Pictures in purgeable pages, on real `VM_FLAGS_PURGABLE` regions: volatile while no
/// image of them lives, locked while one does, and a region emptied while volatile (``VirtualMemoryPurgeablePages/purge()``,
/// as memory pressure would) gives no image, never a blank one. Locked bytes reach the owner's ledger apart from volatile ones.
@Suite struct PurgeableBitmapTests {
    /// The pages the allocator made, to purge one or read its state.
    nonisolated final class Made: Sendable {
        private let pages = Mutex<[VirtualMemoryPurgeablePages]>([])

        var allocator: PurgeableAllocator {
            PurgeableAllocator { [self] count in
                let made = VirtualMemoryPurgeablePages(byteCount: count)
                if let made { pages.withLock { $0.append(made) } }
                return made
            }
        }

        var all: [VirtualMemoryPurgeablePages] { pages.withLock { $0 } }
    }

    /// A `width` x `height` opaque red picture.
    private static func red(width: Int = 20, height: Int = 8) throws -> CGImage {
        let context = try #require(CGContext.bitmapOwningPixels(width: width, height: height, space: CGColorSpaceCreateDeviceRGB(),
                                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The red and alpha of `image`'s first pixel, read back through a fresh RGBA context.
    private static func firstPixel(_ image: CGImage) throws -> (red: UInt8, alpha: UInt8) {
        let context = try #require(CGContext.bitmapOwningPixels(width: 1, height: 1, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try #require(context.makeImage()?.dataProvider?.data as Data?)
        return (pixel[pixel.startIndex], pixel[pixel.startIndex + 3])
    }

    @Test func aBitmapKeepsThePixelsAndPadsRowsTo64Bytes() throws {
        let made = Made()
        let bitmap = try #require(PurgeableBitmap(try Self.red(), allocator: made.allocator))
        #expect(bitmap.bytesPerRow == 128 && bitmap.byteCount == 128 * 8)
        #expect(PurgeableBitmap.byteCount(width: 20, height: 8) == bitmap.byteCount)
        #expect(made.all.count == 1, "one copy at creation")
        let image = try #require(bitmap.image())
        #expect(image.width == 20 && image.height == 8)
        let pixel = try Self.firstPixel(image)
        #expect(pixel.red > 250 && pixel.alpha == 255, "the kept pixels are not the picture's")
        _ = try #require(bitmap.image())
        #expect(made.all.count == 1, "a read made new pages: images wrap the kept pixels")
    }

    /// The acceptance case: an emptied region gives no image (a miss) and stays purged; nothing reads blank pixels.
    @Test func aPurgedBitmapGivesNoImage() throws {
        let made = Made()
        let bitmap = try #require(PurgeableBitmap(try Self.red(), allocator: made.allocator))
        try #require(made.all.count == 1)
        made.all[0].purge()
        #expect(bitmap.image() == nil, "a purged bitmap gave an image")
        #expect(bitmap.isPurged)
        #expect(bitmap.image() == nil, "a purged bitmap came back")
    }

    /// While an image lives its bytes are locked (counted once however many readers), and the last image's
    /// free makes them volatile again: they leave the owner's locked bytes.
    @Test func anImageKeepsItsPixelsLockedUntilItIsFreed() throws {
        let ledger = PurgeableLedger()
        let bitmap = try #require(PurgeableBitmap(try Self.red(), allocator: Made().allocator))
        bitmap.attach(to: ledger)
        #expect(ledger.usage(totalBytes: bitmap.byteCount, entries: 1) == MemoryUsage(footprintBytes: 0, volatileBytes: bitmap.byteCount, entries: 1))
        try withExtendedLifetime(try #require(bitmap.image())) { _ in
            #expect(ledger.lockedBytes == bitmap.byteCount, "a drawn bitmap was not counted as locked")
            try withExtendedLifetime(try #require(bitmap.image())) { _ in
                #expect(ledger.lockedBytes == bitmap.byteCount, "a second reader counted the bytes twice")
            }
            #expect(ledger.lockedBytes == bitmap.byteCount, "the first reader's lock ended with the second's")
        }
        #expect(ledger.lockedBytes == 0, "the last image's free left the bytes locked")
        #expect(ledger.usage(totalBytes: bitmap.byteCount, entries: 1).volatileBytes == bitmap.byteCount)
    }

    /// A cache that drops a bitmap while an image of it is drawn moves its bytes out of its ledger at once;
    /// the image's later free changes nothing there.
    @Test func aDetachedBitmapLeavesTheLedgerWhileDrawn() throws {
        let ledger = PurgeableLedger()
        let bitmap = try #require(PurgeableBitmap(try Self.red(), allocator: Made().allocator))
        bitmap.attach(to: ledger)
        try withExtendedLifetime(try #require(bitmap.image())) { _ in
            #expect(ledger.lockedBytes == bitmap.byteCount)
            bitmap.attach(to: nil)
            #expect(ledger.lockedBytes == 0)
        }
        #expect(ledger.lockedBytes == 0)
    }

    /// Resident pages (`purgeableImageCaches` off) are never purged and always count as locked: the report
    /// stays the footprint it was before.
    @Test func residentPagesAlwaysCountAsLocked() throws {
        let ledger = PurgeableLedger()
        let bitmap = try #require(PurgeableBitmap(try Self.red(), allocator: .resident))
        bitmap.attach(to: ledger)
        #expect(ledger.lockedBytes == bitmap.byteCount)
        _ = try #require(bitmap.image())
        #expect(ledger.lockedBytes == bitmap.byteCount)
        bitmap.attach(to: nil)
        #expect(ledger.lockedBytes == 0)
    }

    /// An encoded picture opens lazily from its locked bytes (no decode here); once purged it gives no image,
    /// and purging one picture's region leaves another's.
    @Test func anEncodedPictureOpensFromItsPagesAndMissesOncePurged() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try Self.red(), nil)
        try #require(CGImageDestinationFinalize(destination))
        let made = Made()
        let picture = try #require(PurgeablePicture(encoded: data as Data, allocator: made.allocator))
        let decoded = try #require(PurgeablePicture(decoding: try Self.red(), allocator: made.allocator))
        #expect(picture.byteCount == data.length)
        #expect(decoded.byteCount == PurgeableBitmap.byteCount(width: 20, height: 8))
        do {
            let image = try #require(picture.image())
            #expect(image.width == 20 && image.height == 8)
        }
        try #require(made.all.count == 2)
        made.all[0].purge()
        #expect(picture.image() == nil, "a purged encoded picture gave an image")
        #expect(decoded.image() != nil, "purging one region took another")
    }
}
