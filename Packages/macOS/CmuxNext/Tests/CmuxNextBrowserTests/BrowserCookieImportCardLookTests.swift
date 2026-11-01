import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import Testing

/// Lawrence, 2026-10-31, on NIGHTLY: "border here looks bad" (the Import Cookies banner over a
/// page). The banner drew the theme-tinted overlay glass with a square gray veil clipped inside
/// it, so its edge read as a dark, heavy outline whose corners did not follow the glass, and it
/// cast no shadow. A prompt over a page is the shared neutral glass of dialogs and prompt bars
/// (`FloatingGlassStyle.dialog`): its soft top-lit rim, its radius and the popups' shadow.
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

    @Test func theBannerIsTheSharedPromptGlass() throws {
        let glass = try #require(Self.card().glass)
        #expect(glass.tone.style == .dialog)
        #expect(glass.cornerRadius == FloatingGlassStyle.dialog.cornerRadius)
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
}
