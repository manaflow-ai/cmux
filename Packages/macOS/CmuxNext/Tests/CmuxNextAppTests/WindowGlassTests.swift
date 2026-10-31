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

    @Test func otherMaterialsAndPlainGlassKeepTheArtOpaque() {
        #expect(WindowBackdrop(Self.tokens(blur: -1), selection: Self.work).artOpacity == 1)
        #expect(WindowBackdrop(Self.tokens(blur: 20), selection: Self.work).artOpacity == 1)
        #expect(WindowBackdrop(Self.tokens(blur: 0), selection: Self.work).artOpacity == 1)
        #expect(WindowBackdrop(Self.tokens(blur: -2)).artOpacity == 1)
        // Reduce Transparency makes the window opaque, art and all.
        #expect(WindowBackdrop(Self.tokens(blur: -2), reduceTransparency: true, selection: Self.work).artOpacity == 1)
    }
}
