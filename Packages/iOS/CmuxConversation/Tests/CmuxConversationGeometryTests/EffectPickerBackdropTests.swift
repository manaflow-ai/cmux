import CmuxConversationGeometry
import CoreGraphics
import Testing

/// Messages' Send with effect backdrop (iOS 26.5 and 27.0 simulators,
/// `CKEffectPickerStandardView`): a linear-light tint rgba(45,66,95,.08)
/// under a radius-64 Gaussian backdrop rendered at half resolution, then a
/// 50 % black overlay (light: 15 % white). Over black Messages reads 1 to 6
/// and the track (plus-lighter gray 40) 44; the thin material we used read 30
/// and 74, and its far smaller radius left bubble shapes legible.
struct EffectPickerBackdropTests {
    @Test func darkHalvesTheBlurUnderBlack() {
        let backdrop = EffectPickerBackdrop(dark: true)
        #expect(backdrop.washWhite == 0)
        #expect(backdrop.washAlpha == 0.5)
        #expect(backdrop.level(overBlurred: 0) <= 1)
        #expect(abs(backdrop.level(overBlurred: 255) - 127.5) < 0.5)
    }

    @Test func lightLiftsTheBlurWithFifteenPercentWhite() {
        let backdrop = EffectPickerBackdrop(dark: false)
        #expect(backdrop.washWhite == 1)
        #expect(backdrop.washAlpha == 0.15)
        #expect(abs(backdrop.level(overBlurred: 0) - 38.25) < 0.5)
    }

    @Test func blursAtMessagesRadiusAndTint() {
        #expect(EffectPickerBackdrop.blurRadius == 64)
        #expect(EffectPickerBackdrop.tint == .init(red: 45, green: 66, blue: 95, alpha: 0.08))
    }

    /// The snapshot is drawn small: a radius-64 blur keeps nothing finer, and
    /// the blur's pixel radius follows the render scale.
    @Test func rendersSmallAndScalesTheRadius() {
        #expect(EffectPickerBackdrop.renderScale == 0.25)
        #expect(EffectPickerBackdrop.pixelRadius == 16)
    }
}
