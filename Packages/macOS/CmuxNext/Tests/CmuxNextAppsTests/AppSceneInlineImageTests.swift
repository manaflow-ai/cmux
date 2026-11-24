import AppKit
@testable import CmuxNextApps
import Foundation
import Testing

/// `Image(src)` draws a small PNG or JPEG data URL (an extension player's artwork from `media.get`),
/// and still nothing for another scheme or an oversized URL.
@MainActor
struct AppSceneInlineImageTests {
    /// A 2x1 PNG.
    private static func png() throws -> String {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        return "data:image/png;base64," + data.base64EncodedString()
    }

    @Test func aPNGDataURLDecodesWithoutABundle() throws {
        let image = AppBundleImageCache.shared.image(path: try Self.png(), in: nil)
        #expect(image?.size.width == 2)
    }

    @Test func otherSchemesBadBytesAndOversizedURLsDrawNothing() throws {
        let cache = AppBundleImageCache.shared
        #expect(cache.image(path: "data:text/html;base64,PGI+", in: nil) == nil)
        #expect(cache.image(path: "data:image/svg+xml;base64,PHN2Zz4=", in: nil) == nil)
        #expect(cache.image(path: "data:image/png;base64,bm90IGFuIGltYWdl", in: nil) == nil)
        let big = "data:image/png;base64," + String(repeating: "A", count: AppBundleImageCache.maxDataURLBytes)
        #expect(cache.image(path: big, in: nil) == nil)
    }
}
