@testable import CmuxScreenKit
import CoreGraphics
import Testing

/// Follow mode's framing: a crop (a fraction of the display) to the scroll
/// view's zoom and offset, and back.
struct ScreenCameraFramingTests {
    /// A 1920x1080 display at the content's origin, a 393x852 portrait view.
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let view = CGSize(width: 393, height: 852)

    @Test func aPortraitCropFillsTheView() {
        // The view's own shape, a third of the display's height, its top left at (960, 540).
        let height = 360.0 / 1080, width = 360.0 * 393 / 852 / 1920
        let framing = ScreenCameraFraming(crop: CGRect(x: 0.5, y: 0.5, width: width, height: height), display: display,
                                          viewSize: view)
        #expect(abs(framing.zoomScale - 852.0 / 360) < 1e-9)
        #expect(abs(framing.contentOffset.x - 960 * framing.zoomScale) < 1e-6)
        #expect(abs(framing.contentOffset.y - 540 * framing.zoomScale) < 1e-6)
    }

    /// A readable crop (half the display's width, its full height) is wider
    /// than the view's shape: it fits by width and sits centred, letterboxed.
    @Test func aWideFullHeightCropIsLetterboxed() {
        let framing = ScreenCameraFraming(crop: CGRect(x: 0.25, y: 0, width: 0.5, height: 1), display: display,
                                          viewSize: view)
        let scale = 393.0 / 960
        #expect(abs(framing.zoomScale - scale) < 1e-9)
        #expect(abs(framing.contentOffset.x - 480 * scale) < 1e-6)
        let shownHeight = 1080 * scale
        #expect(abs(framing.contentOffset.y - -(852 - shownHeight) / 2) < 1e-6, "centred vertically")
    }

    /// A display that is not the content's origin (the second of two).
    @Test func aSecondDisplayOffsetsTheContent() {
        let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let framing = ScreenCameraFraming(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), display: second,
                                          viewSize: view)
        let scale = 393.0 / 960
        #expect(abs(framing.contentOffset.x - 1920 * scale) < 1e-6)
    }

    /// What the person framed reads back as the crop that framed it, cut to the display.
    @Test func visibleIsTheInverse() {
        let crop = CGRect(x: 0.4, y: 0.2, width: 360.0 * 393 / 852 / 1920, height: 360.0 / 1080)
        let framing = ScreenCameraFraming(crop: crop, display: display, viewSize: view)
        let back = framing.visible(display: display, viewSize: view)
        #expect(abs(back.minX - crop.minX) < 1e-9 && abs(back.minY - crop.minY) < 1e-9)
        #expect(abs(back.width - crop.width) < 1e-9 && abs(back.height - crop.height) < 1e-9)
        let letterboxed = ScreenCameraFraming(crop: CGRect(x: 0.25, y: 0, width: 0.5, height: 1), display: display,
                                              viewSize: view)
        let shown = letterboxed.visible(display: display, viewSize: view)
        #expect(abs(shown.height - 1) < 1e-9, "the black bars are not part of the display")
        #expect(abs(shown.minX - 0.25) < 1e-9 && abs(shown.width - 0.5) < 1e-9)
    }
}
