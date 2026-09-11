import AppKit
import Testing
@testable import CmuxTerminalCore

@Suite
struct GhosttyConfigInactiveSplitAppearanceTests {
    @Test
    func defaultInactiveSplitAppearanceDoesNotWashTerminalContent() {
        let config = GhosttyConfig()

        #expect(config.unfocusedSplitOpacity == 1.0)
        #expect(config.unfocusedSplitOverlayOpacity == 0.0)
    }

    @Test(arguments: ["#FFFFFF", "#282C34"])
    func themeColorsDoNotOptIntoInactiveSplitDimming(background: String) {
        var config = GhosttyConfig()
        config.parse("background = \(background)\npalette = 1=#FF0000")

        #expect(config.unfocusedSplitOverlayOpacity == 0.0)
        #expect(config.palette[1]?.hexString() == "#FF0000")
    }

    @Test
    func explicitInactiveSplitAppearanceRemainsIntact() {
        var config = GhosttyConfig()

        config.parse(
            """
            unfocused-split-opacity = 0.7
            unfocused-split-fill = #FDF6E3
            """
        )

        #expect(config.unfocusedSplitOpacity == 0.7)
        #expect(abs(config.unfocusedSplitOverlayOpacity - 0.3) < 0.0001)
        #expect(config.unfocusedSplitFill?.hexString() == "#FDF6E3")

        var fillOnlyConfig = GhosttyConfig()
        fillOnlyConfig.parse("unfocused-split-fill = #FDF6E3")
        #expect(abs(fillOnlyConfig.unfocusedSplitOverlayOpacity - 0.3) < 0.0001)
    }

    @Test
    func explicitFullContrastWinsOverFillInEitherDirectiveOrder() {
        for directives in [
            "unfocused-split-opacity = 1\nunfocused-split-fill = #FDF6E3",
            "unfocused-split-fill = #FDF6E3\nunfocused-split-opacity = 1"
        ] {
            var config = GhosttyConfig()
            config.parse(directives)
            #expect(config.unfocusedSplitOverlayOpacity == 0.0)
        }
    }
}
