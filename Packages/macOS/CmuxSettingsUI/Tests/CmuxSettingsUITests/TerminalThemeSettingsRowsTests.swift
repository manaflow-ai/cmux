import CmuxFoundation
import Testing
@testable import CmuxSettingsUI

/// The Terminal Theme row's subtitle, which says which theme each appearance uses.
@MainActor
@Suite("Terminal theme row subtitle")
struct TerminalThemeSettingsRowsTests {
    @Test("One theme for both appearances names it on both sides")
    func sameThemeNamesBothSides() {
        let subtitle = TerminalThemeSettingsRows.subtitle(
            for: CmuxTerminalThemePair(light: "Builtin Light", dark: "Builtin Light")
        )

        #expect(subtitle == pair("Builtin Light", "Builtin Light"))
    }

    @Test("A light/dark pair names both sides")
    func pairNamesBothSides() {
        let subtitle = TerminalThemeSettingsRows.subtitle(
            for: CmuxTerminalThemePair(light: "Builtin Light", dark: "Builtin Dark")
        )

        #expect(subtitle == pair("Builtin Light", "Builtin Dark"))
    }

    @Test("With no theme set, the row names Ghostty's default colors once")
    func noThemeNamesDefaultOnce() {
        let subtitle = TerminalThemeSettingsRows.subtitle(for: CmuxTerminalThemePair(light: nil, dark: nil))

        #expect(subtitle == String(localized: "settings.terminal.themeGallery.default", defaultValue: "Ghostty default colors", bundle: .module))
    }

    /// Resolved from the CmuxSettingsUI bundle, as the row does, so the
    /// expectation holds in any test locale.
    private func pair(_ light: String, _ dark: String) -> String {
        String.localizedStringWithFormat(
            String(localized: "settings.terminal.themeGallery.pair", defaultValue: "Light: %1$@ · Dark: %2$@", bundle: .module),
            light,
            dark
        )
    }
}
