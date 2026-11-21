import CmuxNextSettingsWindow
import CoreGraphics
import Foundation
import Testing

/// The Density Overlay Playground's pixel diff (``DensityOverlayDiff``): what counts as differing, where, and how an
/// offset lines the reference up.
@Suite struct DensityOverlayDiffTests {
    /// A `width` x `height` white image with black pixels at `dots` (x, y from the top left).
    private func image(width: Int, height: Int, dots: [(Int, Int)] = [], gray: UInt8 = 0) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for (x, y) in dots {
            let i = (y * width + x) * 4
            (bytes[i], bytes[i + 1], bytes[i + 2]) = (gray, gray, gray)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func identicalImagesMatch() {
        let a = image(width: 20, height: 10, dots: [(3, 4)])
        let diff = DensityOverlayDiff(live: a, reference: a)
        #expect(diff.total == 200)
        #expect(diff.differing == 0)
        #expect(diff.bounds == nil)
    }

    @Test func differingPixelsAreCountedAndBounded() {
        let live = image(width: 20, height: 10, dots: [(2, 1), (9, 7)])
        let reference = image(width: 20, height: 10)
        let diff = DensityOverlayDiff(live: live, reference: reference)
        #expect(diff.differing == 2)
        #expect(diff.bounds == CGRect(x: 2, y: 1, width: 8, height: 7))
    }

    /// Anti-aliasing: a channel difference within the tolerance is the same pixel.
    @Test func differencesWithinTheToleranceDoNotCount() {
        let live = image(width: 8, height: 8, dots: [(1, 1)], gray: 240)
        let reference = image(width: 8, height: 8)
        #expect(DensityOverlayDiff(live: live, reference: reference, threshold: 24).differing == 0)
        #expect(DensityOverlayDiff(live: live, reference: reference, threshold: 8).differing == 1)
    }

    /// The reference moved by the offset lines up with a copy of itself drawn that far off.
    @Test func anOffsetLinesTheReferenceUp() {
        let live = image(width: 12, height: 12, dots: [(5, 6)])
        let reference = image(width: 12, height: 12, dots: [(3, 2)])
        #expect(DensityOverlayDiff(live: live, reference: reference).differing == 2)
        #expect(DensityOverlayDiff(live: live, reference: reference, offset: CGPoint(x: 2, y: 4)).differing == 0)
    }
}
