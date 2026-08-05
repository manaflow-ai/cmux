import CMUXMobileCore
import CmuxMobileTerminal
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Test func terminalPaletteProducesOpaqueUIKitColors() {
    var theme = TerminalTheme.monokai
    theme.background = "#999999"
    theme.foreground = "#111111"

    #expect(theme.terminalBackgroundUIColor.cgColor.alpha == 1)
    #expect(theme.terminalForegroundUIColor.cgColor.alpha == 1)
}
