import CMUXMobileCore
import CmuxTheme
import Testing
@testable import CmuxNextDesign

/// A phone showing a Mac's terminal gets that terminal's `TerminalTheme`; its
/// chrome must derive the same tokens the Mac derives from the Ghostty config.
@Suite struct TerminalThemeParityTests {
    @Test func monokaiDerivesTheMacsTokens() {
        let phone = ThemeTokens.derive(from: ThemeInput(terminalTheme: .monokai))
        let mac = ThemeTokens.derive(from: ThemeFixtures.monokaiClassic)
        #expect(phone == mac)
    }
}
