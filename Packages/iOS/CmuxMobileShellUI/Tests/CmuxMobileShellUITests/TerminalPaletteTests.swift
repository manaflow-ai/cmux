import CMUXMobileCore
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Test func terminalPaletteChoosesHigherContrastForeground() {
    var theme = TerminalTheme.monokai
    theme.background = "#999999"

    #expect(theme.terminalChromeForegroundColor == Color.black)
    #expect(theme.terminalColorScheme == .light)
    #expect(MobileTerminalChromeStyle(theme: theme).workspaceBackButtonBadgeContrast == .lightBackground)

    theme.background = "#333333"
    #expect(theme.terminalChromeForegroundColor == Color.white)
    #expect(theme.terminalColorScheme == .dark)
    #expect(MobileTerminalChromeStyle(theme: theme).workspaceBackButtonBadgeContrast == .darkBackground)
}
