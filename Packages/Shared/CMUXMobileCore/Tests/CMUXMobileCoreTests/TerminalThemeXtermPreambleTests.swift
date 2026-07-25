import Foundation
import Testing
@testable import CMUXMobileCore

@Suite("xterm configuration theme preamble")
struct TerminalThemeXtermPreambleTests {
    @Test
    func `Preamble carries the complete validated config theme as bounded base64url JSON`() throws {
        var theme = TerminalTheme.monokai
        theme.background = "#010203"
        theme.foreground = "#a0b0c0"
        theme.cursorText = "#112233"
        theme.palette = (0..<TerminalTheme.extendedPaletteCount).map {
            String(format: "#%06x", $0)
        }

        let bytes = try theme.xtermConfigurationPreambleBytes()
        let text = try #require(String(data: bytes, encoding: .utf8))
        let prefix = "\u{1B}]777;cmux-theme-v1;"
        let suffix = "\u{1B}\\"
        #expect(text.hasPrefix(prefix))
        #expect(text.hasSuffix(suffix))
        #expect(bytes.count < 16 * 1_024)

        let encoded = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        let padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(
                toLength: encoded.count + (4 - encoded.count % 4) % 4,
                withPad: "=",
                startingAt: 0
            )
        let decodedData = try #require(Data(base64Encoded: padded))
        let decoded = try JSONDecoder().decode(TerminalTheme.self, from: decodedData)
        #expect(decoded == theme)
    }

    @Test
    func `Invalid themes cannot enter a baseline preamble`() {
        var theme = TerminalTheme.monokai
        theme.palette = ["#000000"]

        #expect(throws: (any Error).self) {
            try theme.xtermConfigurationPreambleBytes()
        }
    }
}
