import Testing
@testable import CmuxConversationCore

/// Messages underlines a detected date, time, phone number or address in a
/// lighter shade of the text (DataDetectorsUI `lightUnderlineColorFromTextColor:`):
/// white text at 46% opacity, any other color at 26%. On a real iPhone the
/// "8am" in a blue bubble sits on a translucent white line (the simulator's
/// SMS demo runs no detectors, so it underlines nothing).
@Suite struct ConversationDataDetectionUnderlineTests {
    @Test func whiteTextGetsAFortySixPercentLine() {
        #expect(ConversationDataDetection.underlineAlpha(saturation: 0, brightness: 1) == 0.46)
    }

    @Test func darkOrColoredTextGetsATwentySixPercentLine() {
        #expect(ConversationDataDetection.underlineAlpha(saturation: 0, brightness: 0) == 0.26)
        #expect(ConversationDataDetection.underlineAlpha(saturation: 0.8, brightness: 1) == 0.26)
        #expect(ConversationDataDetection.underlineAlpha(saturation: 0, brightness: 0.98) == 0.26)
    }
}
