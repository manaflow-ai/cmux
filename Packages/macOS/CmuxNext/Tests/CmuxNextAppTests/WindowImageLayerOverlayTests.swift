import AppKit
@testable import CmuxNextApp
import Testing

/// A window snapshot's base is the window server's composite of the window with its popovers and
/// menus, and Chromium's own page image is painted over it. Where a popover or menu covers the
/// page, its pixels come back from the composite (`WindowImageLayer.overlay`), so it shows over
/// the page as on screen instead of under the page image.
@MainActor @Suite struct WindowImageLayerOverlayTests {
    private static let side = 40

    private static func image(_ fill: (CGContext) -> Void) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        fill(context)
        return try #require(context.makeImage())
    }

    private static func solid(_ color: CGColor) throws -> CGImage {
        try image { context in
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The RGBA bytes of column `x` (the same in every row of these images).
    private static func pixel(_ image: CGImage, x: Int) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        #expect(drawn)
        let start = (side / 2 * side + x) * 4
        return Array(bytes[start..<start + 4])
    }

    @Test func aPopoverOverAPageImageShowsOverIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless], backing: .buffered, defer: true)
        // The window server's composite: the popover (blue here) over the window.
        let composite = try Self.solid(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        // Chromium's page image fills the window.
        let page = try Self.solid(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        // The popover alone covers the left half.
        let coverage = try Self.image { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        }
        let result = try #require(WindowImageLayer.composite(base: composite, window: window, layers: [
            .page(page, NSRect(x: 0, y: 0, width: side, height: side)),
            .overlay(composite, coverage: coverage),
        ]))
        #expect(try Self.pixel(result, x: 5) == [0, 0, 255, 255])
        #expect(try Self.pixel(result, x: side - 5) == [0, 255, 0, 255])
    }
}
