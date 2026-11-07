import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Testing

/// Lawrence, 2026-10-31, on NIGHTLY: "border here looks bad" (the Import Cookies banner over a
/// page). The banner drew the theme-tinted overlay glass with a square gray veil clipped inside
/// it, so its edge read as a dark, heavy outline whose corners did not follow the glass, and it
/// cast no shadow. It keeps the dialog radius and the popups' shadow, with no veil of its own.
///
/// Leo, 2026-11-06, on NIGHTLY: "The bottom import is unthemed." The neutral gray glass and the
/// browser's plain gray text buttons ignored the app theme, where the browser's other prompts (the
/// prompt bar, notices, the cookie consent panel) draw the theme's glass tint. The banner takes the
/// theme's glass and the app's standard dialog buttons: Import in the theme's accent, Not Now in its gray.
@MainActor @Suite(.serialized) struct BrowserCookieImportCardLookTests {
    static func card() -> BrowserCookieImportCard {
        let offer = BrowserCookieImportOffer(icons: [], title: "Import cookies from Google Chrome",
                                             detail: "Stay signed in to your sites. Nothing leaves this Mac.",
                                             importTitle: "Import…", notNowTitle: "Not Now", neverTitle: "Don't Show Again")
        let card = BrowserCookieImportCard(offer: offer)
        card.frame = NSRect(x: 0, y: 0, width: 460, height: 110)
        card.layoutSubtreeIfNeeded()
        return card
    }

    @Test func theBannerIsTheThemesGlassInTheDialogRadius() throws {
        let glass = try #require(Self.card().glass)
        #expect(glass.tone == .theme)
        #expect(glass.rimView == nil)
        #expect(glass.cornerRadius == FloatingGlassStyle.dialog.cornerRadius)
    }

    @Test func theBannerAnswersWithTheAppsDialogButtons() {
        let card = Self.card()
        #expect(card.importButton.button.role == .default)
        #expect(card.notNowButton.button.role == .cancel)
        // It never takes focus, so it shows no key: Return and Escape belong to the page.
        #expect(card.importButton.keyHint == nil)
        #expect(card.notNowButton.keyHint == nil)
        #expect(card.importButton.keyEquivalent.isEmpty)
        #expect(card.notNowButton.keyEquivalent.isEmpty)
    }

    @Test func theImportButtonIsFilledWithTheThemesAccent() {
        let card = Self.card()
        let tokens = card.themeTokens
        #expect(card.importButton.look.fill == CmuxDialogButtonLook(role: .default, tokens: tokens).fill)
        #expect(card.importButton.look.fill.withAlpha(1) == tokens.accent.withAlpha(1))
        #expect(card.notNowButton.look.fill != card.importButton.look.fill)
    }

    @Test func theBannerHasNoVeilOfItsOwnUnderItsText() throws {
        let glass = try #require(Self.card().glass)
        func veils(_ view: NSView) -> Int {
            (view is OverlayBackingView ? 1 : 0) + view.subviews.map(veils).reduce(0, +)
        }
        #expect(veils(glass) == 0)
    }

    @Test func theBannerCastsThePopupShadow() throws {
        let card = Self.card()
        card.layout()
        let layer = try #require(card.layer)
        #expect(!layer.masksToBounds)
        #expect(layer.shadowOpacity > 0)
        #expect(layer.shadowPath != nil)
    }

    /// The second half of the same report: on macOS 26 the banner still drew a near-black 1 px
    /// line at its top and bottom (fleet capture, 60/255 over a 241/255 page). It floats on the
    /// overlay host, a clear window over the page's window, where Liquid Glass has nothing to
    /// refract and its lens bends the clear pixels into that line. It is the blur of what is
    /// behind its window instead.
    @Test func theBannerBlursThePageBehindItsWindowNeverLiquidGlass() throws {
        let glass = try #require(Self.card().glass)
        #expect(glass.samplesBehindWindow)
        #expect(glass.material != .liquidGlass)
        if glass.material == .vibrancy {
            let blur = try #require(glass.subviews.compactMap { $0 as? NSVisualEffectView }.first)
            #expect(blur.blendingMode == .behindWindow)
        }
    }

    @Test func aSurfaceThatPrefersTheBlurTakesItOverLiquidGlassButKeepsReduceTransparency() {
        let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let surface = OverlaySurfaceView(interactive: true, reduceTransparency: clear, tone: .neutralGlass(.dialog))
        surface.prefersBlurToLiquidGlass = true
        #expect(surface.material != .liquidGlass)
        let opaque = OverlaySurfaceView(interactive: true, reduceTransparency: .alwaysOpaque, tone: .neutralGlass(.dialog))
        opaque.prefersBlurToLiquidGlass = true
        #expect(opaque.material == .opaque)
    }
}
