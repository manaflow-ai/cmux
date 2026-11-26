import Testing
@testable import CmuxMobileDesign

#if os(iOS)
/// 2026-11-25, "for now just make every background black" (the options were PR #53342): shell
/// screens keep the stock ground whatever the Mac's theme. The agent chat is the explicit exception
/// requested by Leo's 2026-11-26 regression report and draws its received Mac look.
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

    @Test func theChatUsesTheSharedMacLook() {
        // Do not inspect process-global cache contents here: the appearance feed owns that state.
        // This assertion locks the chat surface to the shared look rather than silently disabling it.
        #expect(CmuxMobileChatLook.current == CmuxMobileMacTheme.shared.chatLook)
    }
}
#endif
