@testable import CmuxNextDesign
import Foundation
import Testing

/// Window Glass (cx-t2x.6): with the Clear Glass window material, the art turns translucent so the
/// desktop and the windows behind read through it; the glass over it then assumes it could be
/// anything, so text stays legible over whatever shows through.
@MainActor @Suite struct WindowGlassTests {
    static let work = BackdropSelection.art(.vanGoghStarryNight)

    static func tokens(blur: Int) -> ThemeTokens {
        var input = ThemeInput.ghosttyDefault
        input.backgroundBlur = blur
        return ThemeTokens.derive(from: input)
    }

    @Test func clearGlassMakesTheArtTranslucentAndKeepsTextLegibleOverAnything() {
        let tokens = Self.tokens(blur: -2)
        let glass = WindowBackdrop(tokens, selection: Self.work)
        #expect(glass.artOpacity == WindowBackdrop.windowGlassArtOpacity)
        #expect(glass.artOpacity < 1)
        // Whatever is behind the window shows through the art: the floor holds over any colors.
        #expect(glass.legibleTintOpacity == tokens.legibleTintOpacity(over: .any, requested: 0, legibility: .primary))
        #expect(glass.tintOpacity >= glass.legibleTintOpacity)
    }

    @Test func otherMaterialsAndPlainGlassKeepTheArtOpaque() {
        #expect(WindowBackdrop(Self.tokens(blur: -1), selection: Self.work).artOpacity == 1)
        #expect(WindowBackdrop(Self.tokens(blur: 20), selection: Self.work).artOpacity == 1)
        #expect(WindowBackdrop(Self.tokens(blur: 0), selection: Self.work).artOpacity == 1)
        #expect(WindowBackdrop(Self.tokens(blur: -2)).artOpacity == 1)
        // Reduce Transparency makes the window opaque, art and all.
        #expect(WindowBackdrop(Self.tokens(blur: -2), reduceTransparency: true, selection: Self.work).artOpacity == 1)
    }
}
