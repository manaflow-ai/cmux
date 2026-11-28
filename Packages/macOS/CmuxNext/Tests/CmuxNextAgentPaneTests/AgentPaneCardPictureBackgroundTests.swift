@testable import CmuxNextAgentPane
import CoreGraphics
import Testing

/// Leo, 2026-11-27: "the only thing i wanted was that the thumbnail be fixed to reflect the actual bg instead of black
/// screen". A chat's card picture over a see-through ground is laid over what the window shows under the chat, so a
/// clear page pixel takes the window's background (here a red picture), not black and not the card's own fill.
struct AgentPaneCardPictureBackgroundTests {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A `width` x `height` picture, every pixel `rgba` (0-255, straight alpha), or clear with `rgba` nil.
    private static func picture(width: Int, height: Int, rgba: (Double, Double, Double, Double)?) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let rgba {
            context.setFillColor(CGColor(srgbRed: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(context.makeImage())
    }

    /// The first pixel of `image`, premultiplied RGBA bytes.
    private static func firstPixel(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    @Test func aClearPagePixelShowsTheWindowsBackground() throws {
        let page = try Self.picture(width: 64, height: 40, rgba: nil)
        let background = try Self.picture(width: 256, height: 160, rgba: (1, 0, 0, 1))
        let laid = PageImageBackground.laid(page, over: background)
        #expect(laid.width == 64 && laid.height == 40, "the card picture keeps the page's size")
        #expect(try Self.firstPixel(laid) == [255, 0, 0, 255], "a clear page pixel shows the window's red background")
    }

    @Test func anOpaquePagePixelStaysThePage() throws {
        let page = try Self.picture(width: 64, height: 40, rgba: (0, 0, 1, 1))
        let background = try Self.picture(width: 256, height: 160, rgba: (1, 0, 0, 1))
        #expect(try Self.firstPixel(PageImageBackground.laid(page, over: background)) == [0, 0, 255, 255])
    }

    @Test func aSeeThroughBackgroundStaysSeeThrough() throws {
        let page = try Self.picture(width: 64, height: 40, rgba: nil)
        let glass = try Self.picture(width: 64, height: 40, rgba: (1, 1, 1, 0.5))
        let pixel = try Self.firstPixel(PageImageBackground.laid(page, over: glass))
        #expect((126...129).contains(Int(pixel[3])), "a glass window's own translucency is kept, alpha \(pixel[3])")
    }
}
