import CMUXMobileCore
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Test func terminalPaletteChoosesHigherContrastForeground() {
    var theme = TerminalTheme.monokai
    theme.background = "#999999"

    #expect(TerminalPalette.chromeForeground(for: theme) == Color.black)
    #expect(TerminalPalette.colorScheme(for: theme) == .light)

    theme.background = "#333333"
    #expect(TerminalPalette.chromeForeground(for: theme) == Color.white)
    #expect(TerminalPalette.colorScheme(for: theme) == .dark)
}
