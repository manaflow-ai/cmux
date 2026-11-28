@testable import CmuxNextAgentPane
import CoreGraphics
import Testing

/// Leo 2026-11-27, ask-3729c9c563: "there's a (supposed to be) fix for the black bg of the preview in flight". A chat's
/// card picture over a see-through ground keeps its clear pixels; the scale to the card's size kept them black.
struct AgentPaneScaledPictureTests {
    private static func clearPicture(side: Int) -> CGImage? {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }

    @Test func aScaledPictureKeepsItsClearPixelsClear() throws {
        let image = try #require(Self.clearPicture(side: 400))
        let scaled = try #require(AgentPaneVideoInfo.scaled(image, toFit: 100))
        #expect(scaled.width == 100)
        #expect(![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(scaled.alphaInfo), "alpha \(scaled.alphaInfo)")
        let pixel = try #require(scaled.dataProvider?.data.flatMap { CFDataGetBytePtr($0) })
        #expect(pixel[3] == 0, "a clear pixel scaled to alpha \(pixel[3])")
    }
}
