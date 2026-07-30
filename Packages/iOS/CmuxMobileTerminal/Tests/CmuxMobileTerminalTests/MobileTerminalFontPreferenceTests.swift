#if DEBUG
import Testing
@testable import CmuxMobileTerminal

@Suite("MobileTerminalFontPreference")
struct MobileTerminalFontPreferenceTests {
    @Test("clamps terminal zoom to Ghostty's supported range")
    func clampsToSupportedRange() {
        #expect(MobileTerminalFontPreference(clamping: 0).size == 1)
        #expect(MobileTerminalFontPreference(clamping: 1).size == 1)
        #expect(MobileTerminalFontPreference(clamping: 10).size == 10)
        #expect(MobileTerminalFontPreference(clamping: 28).size == 28)
        #expect(MobileTerminalFontPreference(clamping: 29).size == 28)
    }
}
#endif
