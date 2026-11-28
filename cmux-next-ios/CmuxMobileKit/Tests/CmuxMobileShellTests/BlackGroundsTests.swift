import Testing
@testable import CmuxMobileDesign

#if os(iOS)
/// 2026-11-25, "for now just make every background black" (the options were PR #53342): shell
/// screens keep the stock ground whatever the Mac's theme. The agent chat is the explicit exception
/// requested by Leo's 2026-11-26 regression report and draws its received Mac look.
@MainActor
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

    /// The chat takes its look from the theme model, not a stub: a frame with a flat `chat` look gives
    /// that exact ground, a frame without one (or Match Mac theme off) gives none, so the stock ground
    /// stays. Each case is a non-nil, distinct value, so a both-sides-nil comparison cannot pass them.
    @Test func theChatLookFollowsTheMacsFrame() throws {
        let flat = ChatLookTests.theme()
        flat.apply(try #require(CmuxMobileMacAppearance.decode(ChatLookTests.frame(
            chat: ##"{"background":"#1e1e2e","foreground":"#cdd6f4","background_opacity":1}"##))))
        let look = try #require(flat.chatLook, "a flat chat look reaches the chat")
        #expect(look.background == CmuxMobileRGBA(hex: "#1e1e2e"))
        #expect(look.picture == nil)

        let light = ChatLookTests.theme()
        light.apply(try #require(CmuxMobileMacAppearance.decode(ChatLookTests.frame(
            chat: ##"{"background":"#fdf6e3","foreground":"#657b83","background_opacity":1}"##))))
        #expect(try #require(light.chatLook).background == CmuxMobileRGBA(hex: "#fdf6e3"))
        #expect(light.chatLook != flat.chatLook, "two themes give two looks")

        let stock = ChatLookTests.theme()
        stock.apply(try #require(CmuxMobileMacAppearance.decode(ChatLookTests.frame(chat: nil))))
        #expect(stock.chatLook == nil, "no `chat` in the frame keeps the stock ground")
    }
}
#endif
