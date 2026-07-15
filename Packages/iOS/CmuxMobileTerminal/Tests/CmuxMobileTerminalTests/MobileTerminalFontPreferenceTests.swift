#if DEBUG
import Testing
@testable import CmuxMobileTerminal

@Suite("MobileTerminalFontPreference")
struct MobileTerminalFontPreferenceTests {
    @Test("clamps terminal zoom to Ghostty's supported range")
    func clampsToSupportedRange() {
        #expect(MobileTerminalFontPreference.clampedSize(0) == 1)
        #expect(MobileTerminalFontPreference.clampedSize(1) == 1)
        #expect(MobileTerminalFontPreference.clampedSize(10) == 10)
        #expect(MobileTerminalFontPreference.clampedSize(28) == 28)
        #expect(MobileTerminalFontPreference.clampedSize(29) == 28)
    }
}
#endif
