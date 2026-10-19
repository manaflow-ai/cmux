@testable import CmuxNextDesign
import Foundation
import Testing

/// Glass Over Art (`appearance.glassLegibility`): by default the glass keeps only primary text at
/// WCAG AA over the art, like iOS, so far more of the art shows; "all" keeps every text role at
/// its contrast, the denser glass cmux had before.
@MainActor @Suite struct GlassLegibilityTests {
    static let work = BackdropSelection.art(.hokusaiGreatWave)

    @Test func mainTextShowsMoreArtAndKeepsPrimaryTextReadable() throws {
        for input in [ThemeInput.ghosttyDefault] {
            let tokens = ThemeTokens.derive(from: input)
            let range = try #require(Self.work.artRange)
            let primary = tokens.legibleTintOpacity(over: range, requested: 0, legibility: .primary)
            let all = tokens.legibleTintOpacity(over: range, requested: 0, legibility: .all)
            #expect(primary < all)
            // Primary text still holds AA over the work's darkest and lightest colors.
            #expect(range.isLegible(texts: tokens.backdropTexts(.primary), scrim: tokens.surfaceBackground.withAlpha(1),
                                    opacity: primary))
        }
    }

    @Test func allTextHoldsEveryRoleAtItsContrast() throws {
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        let range = try #require(Self.work.artRange)
        let all = tokens.legibleTintOpacity(over: range, requested: 0, legibility: .all)
        #expect(range.isLegible(texts: tokens.backdropTexts(.all), scrim: tokens.surfaceBackground.withAlpha(1), opacity: all))
        #expect(tokens.backdropTexts(.all).count == 3)
        #expect(tokens.backdropTexts(.primary).count == 1)
    }
}
