import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxTheme
import Foundation
import Testing

/// Pages that show code (diff, markdown, editor) draw it in the terminal's face: every page theme
/// carries the family the terminal uses, cmux.json's `terminal.fontFamily`, else the Ghostty
/// config's own `font-family` (appearance.ts `hostTerminalFontFamily`).
@MainActor
struct TerminalFontWebThemeTests {
    private func sentFamily() throws -> Any? {
        let theme = WebTheme(ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))))
        let payload = try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
        let terminal = try #require(payload["terminal"] as? [String: Any])
        return terminal["fontFamily"]
    }

    @Test func theGhosttyConfigFamilyReachesPagesUnlessCmuxJsonNamesOne() throws {
        let settings = DesignSettings.shared
        let saved = (settings.terminalFontFamily, settings.terminalConfigFontFamily)
        defer { (settings.terminalFontFamily, settings.terminalConfigFontFamily) = saved }

        let folder = FileManager.default.temporaryDirectory.appending(path: "terminal-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appending(path: "config")
        try """
        # a comment = not a key
        font-family = Menlo
        font-family = ""
        font-family = "Fira Code"
        font-family = Symbols Nerd Font
        font-size = 14
        """.write(to: config, atomically: true, encoding: .utf8)

        settings.terminalFontFamily = nil
        settings.terminalConfigFontFamily = GhosttyConfigFontFamily.read(environment: ["CMUX_NEXT_GHOSTTY_CONFIG": config.path])
        #expect(try sentFamily() as? String == "Fira Code")

        settings.terminalFontFamily = "Iosevka"
        #expect(try sentFamily() as? String == "Iosevka")

        settings.terminalFontFamily = nil
        settings.terminalConfigFontFamily = GhosttyConfigFontFamily.read(environment: ["CMUX_NEXT_GHOSTTY_CONFIG": folder.appending(path: "missing").path])
        #expect(try sentFamily() is NSNull)
    }
}
