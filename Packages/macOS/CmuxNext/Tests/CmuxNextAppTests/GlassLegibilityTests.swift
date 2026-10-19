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

    /// The window's own backdrop takes the floor the scope's choice names: "all" is denser glass.
    @Test func theBackdropFloorFollowsTheChoice() {
        let tokens = ThemeTokens.derive(from: .ghosttyDefault)
        let primary = WindowBackdrop(tokens, selection: Self.work, legibility: .primary)
        let all = WindowBackdrop(tokens, selection: Self.work, legibility: .all)
        #expect(primary.legibleTintOpacity < all.legibleTintOpacity)
        #expect(all.tintOpacity >= all.legibleTintOpacity)
    }

    /// The choice is set on a scope and inherited by its descendants, like art.
    @Test func descendantsInheritTheScopeChoice() {
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        #expect(workspace.artLegibility == .primary)
        room.setArtLegibility(.all)
        #expect(workspace.artLegibility == .all)
        room.setArtLegibility(.primary)
        #expect(workspace.artLegibility == .primary)
    }
}
