import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextTestSupport
import Testing

/// The globe, the terminal prompt and the sidebar toggle (Leo 2026-11-09: "this icon didnt get drawn or smth",
/// "just draw that basketball instead of that busy thing we have on our top right", a bare >_ prompt, and a
/// sidebar toggle whose bar slides on click).
@MainActor @Suite(.closesItsWindows) struct ToolbarAndTabIconsTests {
    /// A browser tab with no favicon draws the same outlined ball as every other globe, not the one-curve
    /// drawing that read as unfinished; a terminal is the bare prompt at every size.
    @Test func tabsDrawTheSameGlobeAndPromptAsTheToolbar() throws {
        let tabGlobe = try #require(IconPack.bundled.drawing(for: .tabBrowser))
        let globe = try #require(IconPack.bundled.drawing(for: .browser))
        #expect(tabGlobe.line == globe.line)
        let tabPrompt = try #require(IconPack.bundled.drawing(for: .tabTerminal))
        let prompt = try #require(IconPack.bundled.drawing(for: .terminal))
        #expect(tabPrompt.line == prompt.line)
    }

    /// The SF globe (and the globe with a back badge New Browser Tab used) and the SF terminal draw the pack's
    /// glyphs wherever the app draws system symbols; other symbols stay system symbols.
    @Test(arguments: [("globe", IconName.browser), ("globe.badge.chevron.backward", .browser), ("terminal", .terminal)])
    func theseSymbolsDrawThePack(_ symbol: String, _ icon: IconName) {
        #expect(IconCatalog.bundled.name(overriding: symbol) == icon)
        #expect(NSImage.packOverride(forSymbol: symbol, pointSize: 13)?.size == NSSize(width: 17, height: 17))
    }

    @Test func otherSymbolsStaySystemSymbols() {
        #expect(IconCatalog.bundled.name(overriding: "chevron.left") == nil)
        #expect(NSImage.packOverride(forSymbol: "chevron.left", pointSize: 13) == nil)
    }

    /// The pane toolbar's browser and terminal buttons (`TitlebarBandButton`) draw the pack's glyph.
    @Test func toolbarButtonsDrawThePackGlobe() {
        let side = (Metrics.toolbarSymbolPointSize * 4 / 3).rounded()
        #expect(TitlebarBandButton(symbol: "globe").image?.size == NSSize(width: side, height: side))
        #expect(TitlebarBandButton(symbol: "terminal").image?.size == NSSize(width: side, height: side))
    }

    /// The sidebar toggle defaults to the panel whose bar slides; its slide's ends are its two static forms
    /// and every step between draws.
    @Test func thePanelToggleSlidesBetweenItsTwoForms() {
        #expect(SidebarToggleIcon.tunable.defaultValue == .panel)
        #expect(SidebarToggleIcon.slideSymbol(progress: 0) == SidebarToggleIcon.panel.symbol(sidebarHidden: false))
        #expect(SidebarToggleIcon.slideSymbol(progress: 1) == SidebarToggleIcon.panel.symbol(sidebarHidden: true))
        let middle = SidebarToggleIcon.slideSymbol(progress: 0.5)
        #expect(middle != SidebarToggleIcon.slideSymbol(progress: 0) && middle != SidebarToggleIcon.slideSymbol(progress: 1))
        #expect(SidebarToggleIcon.image(named: middle, pointSize: 13) != nil)
    }

    /// Hiding the sidebar slides the bar on the motion clock (at once with motion off) and lands on the hidden
    /// form; showing it again lands back on the shown form.
    @Test func theBandsToggleSlidesToTheSidebarsState() {
        let band = TitlebarToolbarBand(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
        band.iconStore = TunableStore()
        band.showSidebarState(hidden: true)
        band.glyphMotion.motionSettle()
        #expect(band.sidebarToggle.symbol == SidebarToggleIcon.panel.symbol(sidebarHidden: true))
        band.showSidebarState(hidden: false)
        band.glyphMotion.motionSettle()
        #expect(band.sidebarToggle.symbol == SidebarToggleIcon.panel.symbol(sidebarHidden: false))
    }
}
