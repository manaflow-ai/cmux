import Testing
@testable import CmuxNextDesign

struct MistBackdropTests {
    private static let metadata = BackdropArtMetadata(
        focalAnchor: .center,
        tone: .light,
        dominantPalette: [
            BackdropPaletteColor(red: 246, green: 214, blue: 176),
            BackdropPaletteColor(red: 202, green: 223, blue: 238),
        ],
        quietZone: BackdropQuietZone(x: 0.1, y: 0.62, width: 0.8, height: 0.3)
    )

    @Test func gradientScrimRunsAlongTheContentAxis() {
        let plan = MistBackdropPlan(tokens: ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha),
                                    metadata: Self.metadata)

        #expect(plan.gradient.axis == .vertical)
        #expect(plan.gradient.stops.count >= 3)
        #expect(plan.gradient.stops.map(\.location) == plan.gradient.stops.map(\.location).sorted())
        #expect(plan.gradient.stops.first?.color.alpha == 0)
        #expect((plan.gradient.stops.last?.color.alpha ?? 0) > 0.8)
    }

    @Test func cardsAreLocalFrostedSurfaces() {
        let plan = MistBackdropPlan(tokens: ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha),
                                    metadata: Self.metadata)

        #expect(plan.cards.material == .frosted)
        #expect(plan.cards.cornerRadius > 0)
        #expect(plan.cards.fill.alpha > 0)
        #expect(plan.cards.fill.alpha < 1)
        #expect(plan.cards.appliesLocally)
    }

    @Test func cardTextPassesAABasedOnSampledArt() {
        let plan = MistBackdropPlan(tokens: ThemeTokens.derive(from: ThemeFixtures.lowContrast),
                                    metadata: Self.metadata)

        #expect(plan.sampledArt == ThemeRGB(red: 224.0 / 255, green: 218.5 / 255, blue: 207.0 / 255))
        #expect(plan.cards.contrastCheck.minimum == ThemeTokens.minimumTextContrast)
        #expect(plan.cards.contrastCheck.ratio >= ThemeTokens.minimumTextContrast)
        #expect(plan.cards.contrastCheck.passesAA)
    }

    @Test func emptyPaletteFallsBackToThemeSurface() {
        let metadata = BackdropArtMetadata(focalAnchor: .center, tone: .dark,
                                           dominantPalette: [],
                                           quietZone: BackdropQuietZone(x: 0, y: 0, width: 1, height: 1))
        let tokens = ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha)
        let plan = MistBackdropPlan(tokens: tokens, metadata: metadata)

        #expect(plan.sampledArt == tokens.windowBackground.withAlpha(1))
    }
}
