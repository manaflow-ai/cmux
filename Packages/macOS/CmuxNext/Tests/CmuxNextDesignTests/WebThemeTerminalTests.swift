import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// Every web page gets the terminal theme with each theme change (cx-wqn5): the diff viewer and
/// the Markdown page color code from its ANSI palette, as the agent chat and Ghostty do.
struct WebThemeTerminalTests {
    @Test @MainActor func thePagePayloadCarriesTheTerminalPalette() throws {
        let palette = [
            0x606070, 0xFF6060, 0x60FF60, 0xFFFF60, 0x6090FF, 0xFF60FF, 0x60FFFF, 0xC0C0C0,
            0x808090, 0xFF8080, 0x80FF80, 0xFFFF80, 0x80B0FF, 0xFF80FF, 0x80FFFF, 0xFFFFFF,
        ].map { ThemeRGB(hex: UInt32($0)) }
        let input = ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0), palette: palette)
        let theme = WebTheme(ThemeTokens.derive(from: input))

        let payload = try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
        let terminal = try #require(payload["terminal"] as? [String: Any])
        #expect(terminal["background"] as? String == "#101018")
        #expect(terminal["type"] as? String == "dark")
        let sent = try #require(terminal["palette"] as? [String: String])
        #expect(sent.count == 16)
        #expect(sent["5"] == "#ff60ff")
        #expect(sent["15"] == "#ffffff")
    }
}
