import Testing
@testable import CmuxMobileTerminalKit

/// Theme matrix for the iOS shared-sizing chrome: chip text 4.5:1 on its
/// fill, border and chip outline 3:1 on the terminal background, visible
/// fill and hatch.
@Suite struct TerminalSizingPaletteTests {
    struct Theme: Sendable, CustomStringConvertible {
        let name: String
        let background: String
        let foreground: String
        var description: String { name }
    }

    static let themes: [Theme] = [
        Theme(name: "default light", background: "#ffffff", foreground: "#1d1d1f"),
        Theme(name: "default dark", background: "#272822", foreground: "#fdfff1"),
        Theme(name: "solarized light", background: "#fdf6e3", foreground: "#657b83"),
        Theme(name: "solarized dark", background: "#002b36", foreground: "#839496"),
        Theme(name: "low-contrast dark", background: "#1e1e1e", foreground: "#3a3a3a"),
        Theme(name: "pure white", background: "#ffffff", foreground: "#000000"),
        Theme(name: "pure black", background: "#000000", foreground: "#ffffff"),
        Theme(name: "mid grey / white", background: "#808080", foreground: "#ffffff"),
        Theme(name: "mid grey / black", background: "#808080", foreground: "#000000"),
        Theme(name: "dracula", background: "#282a36", foreground: "#f8f8f2"),
        // iOS system backgrounds with label, for the size sheet.
        Theme(name: "iOS system light", background: "#ffffff", foreground: "#000000"),
        Theme(name: "iOS grouped dark", background: "#1c1c1e", foreground: "#ffffff"),
    ]

    @Test(arguments: themes)
    func everyContrastFloorHolds(theme: Theme) throws {
        let background = try #require(TerminalSizingPalette.RGB(hex: theme.background))
        let foreground = try #require(TerminalSizingPalette.RGB(hex: theme.foreground))
        let p = TerminalSizingPalette(background: background, foreground: foreground)
        let ratio = TerminalSizingPalette.contrastRatio
        #expect(ratio(p.glyph, p.fill) >= 4.5, "glyph on fill")
        #expect(ratio(p.text, p.background) >= 4.5, "text on background")
        #expect(ratio(p.line, p.background) >= 3.0, "line on background")
        #expect(ratio(p.fill, p.background) >= 1.2, "fill visible")
        #expect(ratio(p.fill, p.background) < 2.2, "fill subtle")
        #expect(ratio(p.hatch, p.background) >= 1.3, "hatch visible")
    }

    @Test func wcagReferencePoints() throws {
        let white = try #require(TerminalSizingPalette.RGB(hex: "#ffffff"))
        let black = try #require(TerminalSizingPalette.RGB(hex: "#000000"))
        let grey = try #require(TerminalSizingPalette.RGB(hex: "#767676"))
        #expect(abs(TerminalSizingPalette.contrastRatio(white, black) - 21) < 0.01)
        #expect(abs(TerminalSizingPalette.contrastRatio(white, grey) - 4.54) < 0.01)
    }
}
