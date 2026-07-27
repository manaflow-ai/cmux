import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxTerminal

@Suite struct TerminalRuntimeAppearanceTests {
    @Test func preservesResolvedThemeOnTheRuntimeWire() throws {
        let theme = TerminalTheme(
            background: "#102030",
            foreground: "#f0e0d0",
            boldColor: "#abcdef",
            cursor: "#345678",
            cursorColorSemantic: .foreground,
            cursorText: "#fedcba",
            cursorTextSemantic: .background,
            selectionBackground: "#112233",
            selectionBackgroundSemantic: .foreground,
            selectionForeground: "#ddeeff",
            selectionForegroundSemantic: .background,
            palette: (0..<TerminalTheme.paletteCount).map {
                String(format: "#%02x%02x%02x", $0, $0 + 16, $0 + 32)
            }
        )
        let appearance = TerminalRuntimeAppearance(
            fontFamily: "Berkeley Mono",
            fontSizePoints: 14,
            theme: theme
        )

        let data = try JSONEncoder().encode(appearance)
        let decoded = try JSONDecoder().decode(TerminalRuntimeAppearance.self, from: data)

        #expect(decoded == appearance)
        #expect(decoded.theme.palette == theme.palette)
        #expect(decoded.theme.cursorColorSemantic == .foreground)
        #expect(decoded.theme.cursorTextSemantic == .background)
        #expect(decoded.theme.selectionBackgroundSemantic == .foreground)
        #expect(decoded.theme.selectionForegroundSemantic == .background)
    }

    @Test func invalidInputsUseRenderableDefaults() {
        var invalidTheme = TerminalTheme.monokai
        invalidTheme.background = "not-a-color"

        let appearance = TerminalRuntimeAppearance(
            fontFamily: "   ",
            fontSizePoints: .nan,
            theme: invalidTheme
        )

        #expect(appearance.fontFamily == "Menlo")
        #expect(appearance.fontSizePoints == 12)
        #expect(appearance.theme == .monokai)
    }

    @Test func validSurfaceFontOverridePreservesTheme() {
        let appearance = TerminalRuntimeAppearance(
            fontFamily: "Menlo",
            fontSizePoints: 12,
            theme: .monokai
        )

        let overridden = appearance.applyingFontSizeOverride(18)
        let ignored = appearance.applyingFontSizeOverride(0)

        #expect(overridden.fontSizePoints == 18)
        #expect(overridden.fontFamily == appearance.fontFamily)
        #expect(overridden.theme == appearance.theme)
        #expect(ignored == appearance)
    }
}
