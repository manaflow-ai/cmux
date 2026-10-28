import AppKit
import Testing
@testable import MessagesLabSidebar

/// The list's row and tile bitmaps take their size from the host and give bytes back on request:
/// `setBitmapBudget(bytes:)` caps them, `trimBitmaps(toFraction:)` frees the least
/// recently used first, and a budget of 0 keeps nothing.
@MainActor
@Suite(.serialized)
struct SidebarBitmapBudgetTests {
    private static func image(side: Int = 16) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        // SAFETY: the data pointer is nil, so Core Graphics allocates, owns and frees the pixels; nothing of the
        // caller is read or written.
        let ctx = try #require(unsafe CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(ctx.makeImage())
    }

    private static func key(_ n: Int) -> SidebarBitmapKey {
        SidebarBitmapKey(kind: .row, id: "c\(n)", version: 1, width: 300, emphasized: false, generation: 0)
    }

    @Test func theListTrimsToAFractionAndToNothing() throws {
        let list = CmuxSidebarView()
        let image = try Self.image()
        let each = image.bytesPerRow * image.height
        for n in 0..<8 { list.controller.cache.insert(Self.key(n), image) }
        try #require(list.bitmapBytes == 8 * each)
        #expect(list.bitmapCount == 8)

        list.trimBitmaps(toFraction: 0.5)
        #expect(list.bitmapBytes <= 4 * each)
        #expect(list.controller.cache.contains(Self.key(7)), "the newest row lost its bitmap")
        #expect(!list.controller.cache.contains(Self.key(0)), "the oldest row kept its bitmap")
        list.trimBitmaps(toFraction: .nan)
        #expect(list.bitmapBytes > 0, "NaN freed bitmaps")
        list.trimBitmaps(toFraction: 0)
        #expect(list.bitmapBytes == 0)
        #expect(list.bitmapCount == 0)
    }

    @Test func aBudgetOfZeroKeepsNoBitmap() throws {
        let list = CmuxSidebarView()
        let image = try Self.image()
        #expect(list.controller.cache.budget == SidebarBitmapCache.defaultBudget)
        list.setBitmapBudget(bytes: 0)
        list.controller.cache.insert(Self.key(1), image)
        #expect(list.bitmapBytes == 0)
        list.setBitmapBudget(bytes: -1)
        #expect(list.controller.cache.budget == 0)
    }
}
