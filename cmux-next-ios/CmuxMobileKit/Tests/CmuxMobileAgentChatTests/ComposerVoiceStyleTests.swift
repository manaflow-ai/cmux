@testable import CmuxMobileAgentChat
import Testing

/// CMUX-39: the composer shows one filled circle at a time. The voice button is filled
/// only when it is the primary control (no Stop beside it) or voice mode is on.
@Suite struct ComposerVoiceStyleTests {
    @Test func aloneTheVoiceButtonIsTheFilledPrimaryCircle() {
        let style = ComposerVoiceStyle(primaryIsVisible: false, active: false)
        #expect(style.isFilled)
        #expect(style.fill == .neutral)
    }

    @Test func besideStopTheVoiceButtonIsAPlainGlyph() {
        let style = ComposerVoiceStyle(primaryIsVisible: true, active: false)
        #expect(!style.isFilled)
        #expect(style.fill == .plain)
    }

    @Test func voiceModeOnStaysTheAccentCircleEvenBesideStop() {
        for primary in [true, false] {
            let style = ComposerVoiceStyle(primaryIsVisible: primary, active: true)
            #expect(style.isFilled)
            #expect(style.fill == .accent)
        }
    }
}
