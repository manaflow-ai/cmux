import Testing
@testable import CmuxMobileDesign

#if os(iOS)
/// 2026-11-25, "for now just make every background black" (the options were PR #53342): every
/// screen's ground is the stock one whatever the Mac's theme, and the chat draws no Mac look.
@Suite struct BlackGroundsTests {
    @Test func theGroundsAreBlackInDarkAndWhiteInLight() {
        let colors = CmuxMobileColors()
        #expect(colors.bg.dark == CmuxMobileRGBA(hex: "#000000"))
        #expect(colors.bg.light == CmuxMobileRGBA(hex: "#FFFFFF"))
        #expect(colors.bgGrouped.dark == CmuxMobileRGBA(hex: "#000000"))
    }

    @Test func aMacThemeDoesNotColorTheGrounds() {
        // The grounds never read the Mac's palette (surfaces, text and fills still do).
        #expect(CmuxMobileColors().bg == CmuxMobileColors.stockBg)
        #expect(CmuxMobileColors().bgGrouped == CmuxMobileColors.stockBgGrouped)
    }

    @Test func theChatDrawsNoMacLook() {
        #expect(CmuxMobileChatLook.current == nil)
    }
}
#endif
