import CmuxNextSettings
import Testing

/// `openSettings` with `setting: card.NAME` opens the card's page route when `SettingsAnchor` knows no
/// such card. The App Store's Customize cmux… card (Leo, 2026-11-22, ask-931361017e) runs it with
/// `card.customizeChecklist` (Settings > Customize, a page-only category). The What's New tour for the
/// Looks gallery runs it with `card.looksGallery`, a card of Appearance, a category a section opens; the
/// action refused that one ("no setting card.looksGallery in Settings", media run 45837430593).
struct OpenSettingsPageOnlyCardRouteTests {
    @Test func customizeChecklistOpensSettingsCustomize() {
        #expect(SettingsPageLayout.cardRoute("card.customizeChecklist")
            == "#/settings/customize?focus=card.customizeChecklist")
    }

    @Test func aCardOfASectionsCategoryOpensItsCategory() {
        #expect(SettingsPageLayout.cardRoute("card.looksGallery") == "#/settings/appearance?focus=card.looksGallery")
        #expect(SettingsPageLayout.cardRoute("card.customizeLibrary") == "#/settings/appearance?focus=card.customizeLibrary")
        #expect(SettingsPageLayout.cardRoute("card.looksGallery.install") == "#/settings/appearance?focus=card.looksGallery.install")
    }

    @Test func otherSettingsHaveNoCardRoute() {
        #expect(SettingsPageLayout.cardRoute(nil) == nil)
        #expect(SettingsPageLayout.cardRoute("card.noSuchCard") == nil)
        #expect(SettingsPageLayout.cardRoute("appearance.theme") == nil)
    }
}
