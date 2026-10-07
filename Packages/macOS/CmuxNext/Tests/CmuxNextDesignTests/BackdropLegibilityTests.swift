import AppKit
import Testing
@testable import CmuxNextDesign

/// Text stays legible over any art at any opacity (cx-t2x, Leo's hard requirement): the theme's
/// glass over the art never drops below the opacity at which every text role keeps its contrast
/// over black and white art, and panes let the art through that one sheet of glass.
@MainActor
struct BackdropLegibilityTests {
    static let art = BackdropSelection.art(.wheatField)

    @Test(arguments: ThemeFixtures.all.map(\.0))
    func theGlassKeepsEveryTextRoleLegibleOverAnyArt(_ name: String) throws {
        let tokens = try Self.tokens(name)
        for requested in stride(from: 0.0, through: 1.0, by: 0.1) {
            let opacity = BackdropLegibility.tintOpacity(tokens, requested: requested)
            #expect(opacity >= requested - 1e-9)
            let texts = BackdropLegibility.texts(of: tokens), scrim = tokens.surfaceBackground.withAlpha(1)
            // A theme whose own text fails even on its opaque surface gets opaque glass: no art.
            let reachable = BackdropLegibility.isLegible(texts: texts, scrim: scrim, opacity: 1)
            #expect(reachable ? BackdropLegibility.isLegible(texts: texts, scrim: scrim, opacity: opacity) : opacity == 1,
                    "\(name) at \(requested)")
        }
    }

    /// The window's tint over art: the theme's choice or the user's lowered opacity, but never
    /// below the legible glass, even when the user asks for almost none.
    @Test(arguments: ThemeFixtures.all.map(\.0))
    func aLowOpacityCannotMakeTextUnreadableOverArt(_ name: String) throws {
        var input = try #require(ThemeFixtures.all.first { $0.0 == name }?.1)
        input.backgroundOpacity = 0.05
        let tokens = ThemeTokens.derive(from: input)
        let backdrop = WindowBackdrop(tokens, selection: Self.art)
        #expect(backdrop.tintOpacity >= BackdropLegibility.tintOpacity(tokens, requested: 0) - 1e-9)
        // Without art the user's opacity stands: the desktop is behind the glass, not art.
        #expect(WindowBackdrop(tokens).tintOpacity == 0.05)
    }

    /// The experimental glass-transparency tuner lowers the tint, but not past the legible glass.
    @Test func theTunerCannotThinTheGlassPastLegibility() throws {
        let tokens = try Self.tokens("Catppuccin Mocha")
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        var backdrop = WindowBackdrop(tokens, selection: Self.art)
        backdrop.tuning = AppearanceTuning(glassTransparency: 1, hue: 0.5, saturation: 1)
        view.apply(backdrop, tint: tokens.surfaceBackground.nsColor)
        let alpha = try #require(view.subviews.last?.layer?.backgroundColor?.alpha)
        #expect(Double(alpha) >= BackdropLegibility.tintOpacity(tokens, requested: 0) - 0.005)
    }

    /// Over art the panes are glass: they paint nothing of their own, so the art reads through the
    /// window's one legible tint (Home, agent chat, the New Tab page, browser chrome).
    @Test func panesLetTheArtThroughAtFullOpacity() throws {
        let tokens = try Self.tokens("Catppuccin Mocha")
        #expect(tokens.backgroundOpacity == 1)
        #expect(WindowBackdrop(tokens).panesPaintBackground)
        #expect(!WindowBackdrop(tokens, selection: Self.art).panesPaintBackground)
        #expect(WindowBackdrop(tokens, reduceTransparency: true, selection: Self.art).panesPaintBackground)
        let scope = ThemeScope.app
        let previous = scope.backdropSelection
        defer { scope.setBackdropSelection(previous) }
        scope.setBackdropSelection(Self.art)
        #expect(!WindowBackdrop.current(tokens).panesPaintBackground)
        scope.setBackdropSelection(nil)
        #expect(WindowBackdrop.current(tokens).panesPaintBackground)
    }

    private static func tokens(_ name: String) throws -> ThemeTokens {
        ThemeTokens.derive(from: try #require(ThemeFixtures.all.first { $0.0 == name }?.1))
    }
}
