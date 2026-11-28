import CoreGraphics
@testable import CmuxNextApp
import Testing

/// R131: a browser page snapshot (full page size) reaches the hover card
/// already scaled to the card's pixel size, so the first show draws no
/// full-page image in a frame.
struct TabPreviewFittingTests {
    func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func aPageSnapshotFitsTheCard() async {
        let fitted = await TabPreviewFitting.fit(image(2400, 1600), CGSize(width: 480, height: 270))
        #expect(fitted.width <= 480 && fitted.height <= 270)
        #expect(fitted.width == 405 || fitted.height == 270, "aspect kept, height-bound")
        let small = image(100, 50)
        #expect(await TabPreviewFitting.fit(small, CGSize(width: 480, height: 270)) === small, "never scaled up")
    }
}
