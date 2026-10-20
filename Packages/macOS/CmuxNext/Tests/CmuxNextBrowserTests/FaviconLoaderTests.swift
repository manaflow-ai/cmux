import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextBrowser

struct FaviconLoaderTests {
    @Test func hugeAdvertisedDimensionsAreRejectedBeforeDecoding() throws {
        // A valid SVG can advertise enormous dimensions in very few bytes.
        let data = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"><rect width="100000" height="100000" fill="red"/></svg>"#.utf8)
        #expect(BrowserFaviconLoader.decode(data) == nil)
    }

    @Test func rasterThumbnailKeepsTheAspectRatioWithinThePixelBudget() throws {
        let context = try #require(CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        let source = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = try #require(BrowserFaviconLoader.decode(data as Data))
        let decoded = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(decoded.width == 64)
        #expect(decoded.height == 32)
    }
}
