import AppKit
@testable import CmuxNextScreenshots
import Testing

/// A window image of a page with DevTools docked below it (Inspect Element, fleet capture
/// 2026-11-08): the page's image fills only the page's own area, and the DevTools area shows
/// Chromium's image of DevTools, or stripes that say it was not captured, never blank.
struct DockedDevToolsWindowImageTests {
    static let size = CGSize(width: 200, height: 100)
    static let devToolsArea = NSRect(x: 0, y: 0, width: 200, height: 40)
    static let pageArea = NSRect(x: 0, y: 44, width: 200, height: 56)

    /// A solid sRGB image `width` x `height` pixels large.
    static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 200, height: Int = 100) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// The RGB of every pixel of `image` in `rect` (points of a window `size` large, bottom-left origin).
    static func colors(_ image: CGImage, in rect: NSRect) throws -> Set<[UInt8]> {
        let width = image.width, height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scaleX = CGFloat(width) / size.width, scaleY = CGFloat(height) / size.height
        var found = Set<[UInt8]>()
        for y in Int(rect.minY * scaleY)..<Int(rect.maxY * scaleY) {
            for x in Int(rect.minX * scaleX)..<Int(rect.maxX * scaleX) {
                // Rows in memory run top first.
                let index = ((height - 1 - y) * width + x) * 4
                found.insert(Array(bytes[index..<index + 3]))
            }
        }
        return found
    }

    @Test func devToolsChromiumGaveNoImageOfShowStripesBesideThePage() throws {
        let base = try Self.solid(1, 1, 1)
        let page = try Self.solid(0, 0, 1, width: 200, height: 56)
        let image = try #require(WindowImageLayer.composite(base: base, windowSize: Self.size, layers:
            WindowImageLayer.chromiumPage(page, Self.pageArea, devTools: (area: Self.devToolsArea, image: nil))))
        let striped = try Self.colors(image, in: Self.devToolsArea.insetBy(dx: 2, dy: 2))
        let (dark, light) = WindowImageLayer.notCapturedColors
        let expected = try [dark, light].map { color in try #require(color.components).prefix(3).map { UInt8(($0 * 255).rounded()) } }
        #expect(expected.allSatisfy { striped.contains($0) }, "both stripe colors: \(striped.prefix(6))")
        #expect(!striped.contains([255, 255, 255]), "a blank pixel in the DevTools area")
        #expect(try Self.colors(image, in: Self.pageArea.insetBy(dx: 1, dy: 1)) == [[0, 0, 255]])
    }

    @Test func devToolsImageAndPageImageEachFillTheirOwnArea() throws {
        let base = try Self.solid(1, 1, 1)
        let devTools = try Self.solid(1, 0, 0, width: 200, height: 40)
        let page = try Self.solid(0, 0, 1, width: 200, height: 56)
        let image = try #require(WindowImageLayer.composite(base: base, windowSize: Self.size, layers:
            WindowImageLayer.chromiumPage(page, Self.pageArea, devTools: (area: Self.devToolsArea, image: devTools))))
        #expect(try Self.colors(image, in: Self.devToolsArea.insetBy(dx: 1, dy: 1)) == [[255, 0, 0]])
        #expect(try Self.colors(image, in: Self.pageArea.insetBy(dx: 1, dy: 1)) == [[0, 0, 255]])
        // The divider between them keeps the window's own pixels.
        #expect(try Self.colors(image, in: NSRect(x: 0, y: 41, width: 200, height: 2)) == [[255, 255, 255]])
    }
    /// A rounded pane gives the page window a clip, worked out from the page's own area
    /// (`CEFTab.pageWindowClip`); the DevTools image beside the page is not cut away by it
    /// (fleet probe 2026-11-09: Chromium's DevTools image arrived, the window image showed blank).
    @Test func devToolsImageShowsWhenThePageWindowHasARoundedClip() throws {
        let base = try Self.solid(1, 1, 1)
        let devTools = try Self.solid(1, 0, 0, width: 200, height: 40)
        let page = try Self.solid(0, 0, 1, width: 200, height: 56)
        let clip = CGPath(roundedRect: Self.pageArea, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let image = try #require(WindowImageLayer.composite(base: base, windowSize: Self.size, layers:
            WindowImageLayer.chromiumPage(page, Self.pageArea, clip: clip, devTools: (area: Self.devToolsArea, image: devTools))))
        #expect(try Self.colors(image, in: Self.devToolsArea.insetBy(dx: 1, dy: 1)) == [[255, 0, 0]])
        #expect(try Self.colors(image, in: Self.pageArea.insetBy(dx: 8, dy: 8)) == [[0, 0, 255]])
    }
}
