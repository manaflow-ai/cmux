import CmuxTheme
import AppKit
@testable import CmuxNextDesign
import Testing

struct AgentIdentityToneTests {
    @MainActor @Test func retrySpinnerKeepsTheHostIdentityAfterRepaint() throws {
        let spinner = StatusIndicatorView.spinner()
        spinner.spinnerColor = .systemPurple
        spinner.updateLayer()
        #expect(spinner.indicator.colors?.spinner == NSColor.systemPurple.cgColor)
        spinner.spinnerColor = nil
        spinner.updateLayer()
        #expect(spinner.indicator.colors?.spinner != NSColor.systemPurple.cgColor)
    }
    @Test(arguments: [true, false]) func identityUsesTheSharedPaletteAndInk(dark: Bool) {
        let tokens = ThemeTokens.derive(from: ThemeInput(
            background: ThemeRGB(hex: dark ? 0x171717 : 0xFAFAFA),
            foreground: ThemeRGB(hex: dark ? 0xFAFAFA : 0x171717)))
        for (tone, index) in [2, 5, 3, 6, 13].enumerated() {
            #expect(AgentIdentityTone.rgb(tone, tokens: tokens) ==
                    tokens.ansi[index].mixed(toward: tokens.textPrimary, dark ? 0.28 : 0.42))
        }
        #expect(AgentIdentityTone.rgb(nil, tokens: tokens) == nil)
        #expect(AgentIdentityTone.rgb(-1, tokens: tokens) == nil)
        #expect(AgentIdentityTone.rgb(5, tokens: tokens) == nil)
    }
}
