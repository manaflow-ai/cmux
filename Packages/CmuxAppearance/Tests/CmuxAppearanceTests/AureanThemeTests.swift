import Observation
import SwiftUI
import Testing
@testable import CmuxAppearance

@MainActor
@Suite("Aurean theme provider")
struct AureanThemeTests {

    @Test("Default owner resolves to the cool palette")
    func defaultVariant() {
        let theme = AureanTheme()
        #expect(theme.variant == .cool)
        #expect(theme.palette == AureanPalette(variant: .cool))
    }

    @Test("Switching variant re-resolves the palette")
    func switchVariant() {
        let theme = AureanTheme(variant: .cool)
        theme.variant = .obsidian
        #expect(theme.palette == AureanPalette(variant: .obsidian))
        #expect(theme.palette.surfacePrimary == AureanColor(hex: "#15171A"))
    }

    @Test("Mutating variant notifies observers")
    func observationFires() async {
        let theme = AureanTheme(variant: .cool)
        await confirmation("palette observation fires on variant change") { fired in
            withObservationTracking {
                _ = theme.palette
            } onChange: {
                fired()
            }
            theme.variant = .dune
        }
    }

    @Test("warn/crit survive a variant switch (muscle-memory invariant holds through the owner)")
    func signalsSurviveSwitch() {
        let theme = AureanTheme(variant: .cool)
        let warn = theme.palette.warn
        let crit = theme.palette.crit
        theme.variant = .warm
        #expect(theme.palette.warn == warn)
        #expect(theme.palette.crit == crit)
    }

    @Test("Environment palette defaults to cool when no theme is injected")
    func environmentDefault() {
        let env = EnvironmentValues()
        #expect(env.aureanPalette == AureanPalette(variant: .cool))
    }

    @Test("Environment palette carries an explicitly set palette")
    func environmentOverride() {
        var env = EnvironmentValues()
        env.aureanPalette = AureanPalette(variant: .dune)
        #expect(env.aureanPalette == AureanPalette(variant: .dune))
    }
}
