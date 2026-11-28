@testable import CmuxNextAgentPane
import CoreGraphics
import Testing

/// Leo, 2026-11-27: "the hover thumbnail should show the real background, not a black screen". A chat's card picture
/// keeps the page's clear pixels over a glass or picture ground; scaling it drew them into a bitmap with no alpha,
/// which turned them black on the card.
@MainActor struct AgentPanePicturesAlphaTests {
    private static func image(width: Int, height: Int, alpha: Bool) throws -> CGImage {
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        if !alpha {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(context.makeImage())  // alpha: every pixel clear
    }

    private static func alphaOfFirstPixel(_ image: CGImage) throws -> UInt8 {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.data).load(fromByteOffset: 3, as: UInt8.self)
    }

    @Test func scalingAClearPictureKeepsItClear() throws {
        let scaled = try #require(AgentPaneVideoInfo.scaled(try Self.image(width: 1600, height: 1000, alpha: true), toFit: 640))
        #expect(scaled.width == 640)
        #expect(try Self.alphaOfFirstPixel(scaled) == 0, "a clear pixel stays clear, so the card's fill shows, not black")
    }

    @Test func scalingAnOpaquePictureStaysOpaque() throws {
        let scaled = try #require(AgentPaneVideoInfo.scaled(try Self.image(width: 1600, height: 1000, alpha: false), toFit: 640))
        #expect(try Self.alphaOfFirstPixel(scaled) == 255)
    }
}
