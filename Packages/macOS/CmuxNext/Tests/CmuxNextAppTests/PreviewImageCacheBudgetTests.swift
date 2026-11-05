import CmuxNextBridge
import CoreGraphics
import Testing

/// The preview store never holds more than its byte budget (review of #34191). A picture is kept decoded at once and
/// replaced by its compressed copy later (`PreviewImageCache.replace`). A "compressed" copy can be larger than the
/// decoded one (a PNG of a noisy transparent page, a very small picture with JPEG headers); the replace then added bytes
/// with no eviction, and the store grew past its budget until the next insert.
@MainActor @Suite struct PreviewImageCacheBudgetTests {
    /// A 10 x 10 picture: 400 bytes decoded.
    private static func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func aLargerCopyNeverTakesTheStorePastItsBudget() throws {
        let cache = PreviewImageCache(capacityBytes: 1_200)
        let (a, b, c) = (try Self.picture(), try Self.picture(), try Self.picture())
        cache.insert(a, for: "a")
        cache.insert(b, for: "b")
        cache.insert(c, for: "c")
        #expect(cache.totalBytes == 1_200, "three decoded pictures fill the budget")

        cache.replace(b, for: "b", with: try Self.picture(), cost: 600)
        #expect(cache.totalBytes <= cache.capacityBytes, "a replace took the store to \(cache.totalBytes) of \(cache.capacityBytes) bytes")
        #expect(cache.count == 3, "a copy that saves no bytes costs no other tab its picture")
    }

    @Test func aSmallerCopyReplacesTheDecodedOne() throws {
        let cache = PreviewImageCache(capacityBytes: 1_200)
        let a = try Self.picture(), copy = try Self.picture()
        cache.insert(a, for: "a")
        #expect(cache.replace(a, for: "a", with: copy, cost: 100))
        #expect(cache.image(for: "a") === copy)
        #expect(cache.totalBytes == 100)
    }
}
