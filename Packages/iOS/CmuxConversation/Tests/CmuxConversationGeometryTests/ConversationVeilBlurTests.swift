import CmuxConversationGeometry
import CoreGraphics
import Testing

/// Messages' details page blurs the transcript with a pure radius-16
/// Gaussian (no saturation, no tint) under a 60 % white (dark: black) veil.
/// UIKit has no public pure blur, so the page holds the ultra-thin system
/// material part way and lightens the veil to match. The values were fitted
/// in iOS 26.5 and 27.0 simulators against `effectWithBlurRadius:16` over a
/// test pattern of black, white, gray, blue and green patches.
struct ConversationVeilBlurTests {
    @Test func detailsLightMatchesMessagesPureBlur() {
        let veil = ConversationVeilBlur.details(dark: false)
        #expect(veil.materialShare == 0.65)
        #expect(veil.washAlpha == 0.49)
        #expect(veil.washWhite == 1)
    }

    @Test func detailsDarkMatchesMessagesPureBlur() {
        let veil = ConversationVeilBlur.details(dark: true)
        #expect(veil.materialShare == 0.55)
        #expect(veil.washAlpha == 0.55)
        #expect(veil.washWhite == 0)
    }
}
