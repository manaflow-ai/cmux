@testable import CmuxNextDesign
import Foundation
import Testing

/// Window Glass (cx-t2x.6): with the Clear Glass window material, the art turns translucent so the
/// desktop and the windows behind read through it. The tint over it is the Opacity asked for.
@MainActor @Suite struct WindowGlassTests {
    static let work = BackdropSelection.art(.vanGoghStarryNight)

    static func tokens(blur: Int) -> ThemeTokens {
        var input = ThemeInput.ghosttyDefault
        input.backgroundBlur = blur
        return ThemeTokens.derive(from: input)
    }

    @Test func clearGlassMakesTheArtTranslucent() {
        let tokens = Self.tokens(blur: -2)
        let glass = WindowBackdrop(tokens, selection: Self.work)
        #expect(glass.artOpacity == WindowBackdrop.windowGlassArtOpacity)
        #expect(glass.artOpacity < 1)
        #expect(WindowBackdrop(tokens, selection: Self.work, tintOpacity: 0.2).tintOpacity == 0.2)
    }

    /// The art leads and the desktop shows only a little (Leo, 2026-11-07: "the point is to have the
    /// art show through and be shown nicely / the desktop ehhh i guess a little"); at 0.55 the
    /// desktop was nearly half the picture.
    @Test func theArtLeadsAndTheDesktopShowsALittle() {
        let glass = WindowBackdrop(Self.tokens(blur: -2), selection: Self.work)
        #expect(glass.artOpacity >= 0.8)
        #expect(!glass.hidesWhatIsBehind)
    }

    /// A page's glass (the composer, Session Info, menus) refracts Window Glass's art, as it does
    /// opaque art; before, any art under 0.98 left it plain blur, so none of the art came through.
    @Test func pageGlassRefractsWindowGlassArt() {
        let glass = WindowBackdrop(Self.tokens(blur: -2), selection: Self.work)
        #expect(WindowMaterialView.refractsArt(opacity: Float(glass.artOpacity)))
        #expect(WindowMaterialView.refractsArt(opacity: 1))
        #expect(!WindowMaterialView.refractsArt(opacity: 0.5))
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
