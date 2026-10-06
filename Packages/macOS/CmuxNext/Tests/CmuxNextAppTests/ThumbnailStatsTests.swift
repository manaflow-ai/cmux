import CoreGraphics
import Testing
@testable import CmuxNextApp

/// R131 live proof: `debug.hover_sweep` tells a real page thumbnail from a
/// blank capture.
struct ThumbnailStatsTests {
    func image(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    @Test func aFlatCaptureIsBlankAndAPageWithContentIsNot() async throws {
        let blank = try image { $0.setFillColor(gray: 1, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 40)) }
        let page = try image { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            context.setFillColor(gray: 0, alpha: 1)
            for row in stride(from: 4, to: 40, by: 8) { context.fill(CGRect(x: 4, y: row, width: 40, height: 3)) }
        }
        let flat = try #require(await ThumbnailStats.measure(blank))
        #expect(flat.isBlank)
        #expect(flat.width == 64 && flat.height == 40)
        let text = try #require(await ThumbnailStats.measure(page))
        #expect(!text.isBlank, "text lines on a page: variance \(text.variance)")
    }
}
