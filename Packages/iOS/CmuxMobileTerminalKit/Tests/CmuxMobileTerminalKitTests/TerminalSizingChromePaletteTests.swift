import Testing
@testable import CmuxMobileTerminalKit

/// The iOS surface's sizing chrome: grid border and chip outline in the
/// system separator color (the gray of the terminal chrome's other lines),
/// a fainter hatch with no fill, and contrast-safe chip text.
@Suite struct TerminalSizingChromePaletteTests {
    typealias RGB = TerminalSizingPalette.RGB

    static let themes = TerminalSizingPaletteTests.themes

    /// A translucent separator, as the system draws it over the background.
    static func separator(over background: RGB, dark: Bool) -> RGB {
        dark
            ? background.mixed(toward: RGB(red: 84 / 255, green: 84 / 255, blue: 88 / 255), by: 0.6)
            : background.mixed(toward: RGB(red: 60 / 255, green: 60 / 255, blue: 67 / 255), by: 0.29)
    }

    @Test(arguments: themes)
    func borderIsTheSeparatorAndHatchIsFainterWithNoFill(theme: TerminalSizingPaletteTests.Theme) throws {
        let background = try #require(RGB(hex: theme.background))
        let foreground = try #require(RGB(hex: theme.foreground))
        let dark = TerminalSizingChromePalette.usesDarkSeparator(onBackground: background)
        let separator = Self.separator(over: background, dark: dark)
        let palette = TerminalSizingChromePalette(background: background, foreground: foreground, line: separator)
        #expect(palette.line == separator, "border is the separator")
        #expect(palette.hatch == background.mixed(toward: separator, by: TerminalSizingChromePalette.hatchOpacity))
        #expect(palette.chipFill == background, "chip fill is the terminal background")
        let ratio = TerminalSizingPalette.contrastRatio
        #expect(ratio(palette.hatch, background) <= ratio(palette.line, background) + 0.001, "hatch never brighter than the border")
        #expect(ratio(palette.text, palette.chipFill) >= 4.5, "chip text on its fill")
    }

    /// The separator resolves in the appearance the terminal chrome uses:
    /// dark on dark themes, light on light ones, whatever the system is.
    @Test func separatorAppearanceFollowsTheTerminalBackground() throws {
        #expect(TerminalSizingChromePalette.usesDarkSeparator(onBackground: try #require(RGB(hex: "#272822"))))
        #expect(TerminalSizingChromePalette.usesDarkSeparator(onBackground: try #require(RGB(hex: "#282a36"))))
        #expect(!TerminalSizingChromePalette.usesDarkSeparator(onBackground: try #require(RGB(hex: "#fdf6e3"))))
        #expect(!TerminalSizingChromePalette.usesDarkSeparator(onBackground: try #require(RGB(hex: "#ffffff"))))
    }
}
