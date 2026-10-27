import CoreGraphics
import Testing
@testable import CmuxVNC

struct ScreenLayoutTests {
    /// A gray-ish desktop with a pure black void, like macOS Screen Sharing sends.
    func image(width: Int, height: Int, void: CGRect? = nil) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let inVoid = void?.contains(CGPoint(x: x, y: y)) ?? false
                pixels[y * width + x] = inVoid ? 0xFF00_0000 : 0xFF00_0000 | UInt32((x * 7 + y * 3) % 200 + 20)
            }
        }
        return pixels
    }

    func detect(_ pixels: [UInt32], _ width: Int, _ height: Int) -> [CGRect] {
        VNCScreenLayout().screens(pixels: pixels, width: width, height: height, rowPixels: width)
    }

    @Test func macWithAShorterSecondDisplay() {
        // 1920x1080 main, 1024x768 to its right, top-aligned (the 2944x1080 Screen Sharing frame).
        let pixels = image(width: 2944, height: 1080, void: CGRect(x: 1920, y: 768, width: 1024, height: 312))
        #expect(detect(pixels, 2944, 1080) == [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1024, height: 768)])
    }

    @Test func unpaintedSecondDisplayIsStillAPage() {
        // The first update: only the main display painted, the rest black.
        let pixels = image(width: 2944, height: 1080, void: CGRect(x: 1920, y: 0, width: 1024, height: 1080))
        #expect(detect(pixels, 2944, 1080) == [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1024, height: 1080)])
    }

    @Test func singleDisplayIsOnePage() {
        #expect(detect(image(width: 1920, height: 1080), 1920, 1080).isEmpty)
    }

    @Test func darkContentNearAnEdgeIsNotADisplay() {
        // A 100-column dark strip at the bottom (a window edge), narrower than a display.
        let pixels = image(width: 1920, height: 1080, void: CGRect(x: 600, y: 1000, width: 100, height: 80))
        #expect(detect(pixels, 1920, 1080).isEmpty)
    }

    @Test func equalDisplaysSideBySideSplitEvenly() {
        #expect(detect(image(width: 3840, height: 1080), 3840, 1080) == [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1920, height: 1080)])
    }

    /// Fewer words than width x height (or rows narrower than the width) is no layout,
    /// never a read past the pixels.
    @Test func shortPixelsAreNoLayout() {
        let pixels = image(width: 3840, height: 1080)
        #expect(VNCScreenLayout().screens(pixels: Array(pixels.dropLast()), width: 3840, height: 1080, rowPixels: 3840).isEmpty)
        #expect(VNCScreenLayout().screens(pixels: pixels, width: 3840, height: 1080, rowPixels: 3839).isEmpty)
    }

    /// Rows wider than the frame (a pixel buffer's padded stride) read only the frame's columns.
    @Test func paddedRowsReadTheFrameColumns() {
        let width = 3840, height = 1080, rowPixels = 3904
        let frame = image(width: width, height: height)
        var padded = [UInt32](repeating: 0xFF00_0000, count: rowPixels * height)
        for y in 0 ..< height {
            padded.replaceSubrange(y * rowPixels ..< y * rowPixels + width, with: frame[y * width ..< (y + 1) * width])
        }
        let screens = VNCScreenLayout().screens(pixels: padded, width: width, height: height, rowPixels: rowPixels)
        #expect(screens == detect(frame, width, height))
    }
}
