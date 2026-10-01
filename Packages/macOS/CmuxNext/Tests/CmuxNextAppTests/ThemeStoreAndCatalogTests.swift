import Testing
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextOnboarding

/// Terminal themes (app-local) and the theme list every picker offers.
@MainActor @Suite struct ThemeStoreAndCatalogTests {
    @Test func pickersOfferOnboardingsThemes() {
        #expect(ActionArgument.curatedThemes == ThemeChoice.curated)
    }

    @Test func terminalThemesSetClearAndPrune() {
        let store = TerminalThemeStore(url: nil)
        let a = TerminalThemeStore.key(machine: "local", tab: "tab_a")
        let b = TerminalThemeStore.key(machine: "local", tab: "tab_b")
        let remote = TerminalThemeStore.key(machine: "build-box", tab: "tab_c")
        store.set("Nord", for: a)
        store.set("Vesper", for: b)
        store.set("TokyoNight", for: remote)
        #expect(store.theme(for: a) == "Nord")
        store.set(nil, for: a)
        #expect(store.theme(for: a) == nil)
        // A closed terminal's theme goes; other machines are untouched.
        store.prune(machine: "local", liveTabs: [])
        #expect(store.theme(for: b) == nil)
        #expect(store.theme(for: remote) == "TokyoNight")
    }
}
