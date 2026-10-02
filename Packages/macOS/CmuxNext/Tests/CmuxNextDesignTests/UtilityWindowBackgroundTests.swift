import AppKit
import Testing
@testable import CmuxNextDesign

/// Settings and other utility windows paint the theme's window background
/// opaque: a see-through main window (background-opacity, glass) never
/// makes them hard to read.
@MainActor @Suite(.serialized) struct UtilityWindowBackgroundTests {
    @Test(arguments: [1.0, 0.6])
    func isTheWindowBackgroundOpaque(opacity: Double) throws {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = opacity
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        let (utility, window) = room.perform { (Palette.utilityWindowBackground, Palette.windowBackground) }
        let color = try #require(utility.usingColorSpace(.sRGB))
        let expected = ThemeTokens.derive(from: input).windowBackground
        #expect(abs(color.redComponent - expected.red) < 0.01)
        #expect(abs(color.greenComponent - expected.green) < 0.01)
        #expect(abs(color.blueComponent - expected.blue) < 0.01)
        #expect(color.alphaComponent == 1)
        // The main window's own background keeps the configured opacity.
        #expect(abs((window.usingColorSpace(.sRGB)?.alphaComponent ?? 0) - opacity) < 0.01)
    }
}
