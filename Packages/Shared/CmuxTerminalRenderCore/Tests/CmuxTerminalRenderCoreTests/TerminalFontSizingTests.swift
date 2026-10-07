import CmuxTerminalRenderCore
import Testing

@Suite struct TerminalFontSizingTests {
    let sizing = TerminalFontSizing()

    @Test func defaultCategoryIsTheBaseSize() {
        #expect(sizing.fontSize(dynamicTypeScale: 1) == 13)
    }

    @Test func dynamicTypeScalesAndRoundsToHalfPoints() {
        // AX sizes scale the body style by about 1.35 to 3.
        #expect(sizing.fontSize(dynamicTypeScale: 1.35) == 17.5)
        #expect(sizing.fontSize(dynamicTypeScale: 0.82) == 10.5)
    }

    @Test func clampsAtTheExtremes() {
        #expect(sizing.fontSize(dynamicTypeScale: 3.1, zoom: 3) == 36)
        #expect(sizing.fontSize(dynamicTypeScale: 0.1) == 7)
        #expect(sizing.fontSize(dynamicTypeScale: .nan) == 13)
        #expect(sizing.fontSize(dynamicTypeScale: -1) == 13)
    }

    @Test func pinchZoomMultipliesAndClamps() {
        #expect(sizing.zoom(startZoom: 1, pinchScale: 1.5) == 1.5)
        #expect(sizing.zoom(startZoom: 2, pinchScale: 4) == 3)
        #expect(sizing.zoom(startZoom: 1, pinchScale: 0.01) == 0.5)
        #expect(sizing.zoom(startZoom: 1.2, pinchScale: 0) == 1.2)
        #expect(sizing.fontSize(dynamicTypeScale: 1, zoom: 1.5) == 19.5)
    }
}
