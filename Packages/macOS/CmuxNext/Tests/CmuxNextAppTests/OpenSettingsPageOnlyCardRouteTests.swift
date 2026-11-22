@testable import CmuxNextApp
import Testing

/// The App Store's Customize cmux… card (Leo, 2026-11-22, ask-931361017e) runs `openSettings` with
/// `setting: card.customizeChecklist`. Settings > Customize is a page-only category (no section alias),
/// so the action opens its page route; a card of a category a section opens keeps the section route.
struct OpenSettingsPageOnlyCardRouteTests {
    @Test func customizeChecklistOpensSettingsCustomize() {
        #expect(WindowHandlers.pageOnlyCardRoute("card.customizeChecklist")
            == "#/settings/customize?focus=card.customizeChecklist")
    }

    @Test func otherSettingsKeepTheirSectionRoute() {
        #expect(WindowHandlers.pageOnlyCardRoute(nil) == nil)
        #expect(WindowHandlers.pageOnlyCardRoute("card.customizeLibrary") == nil)
        #expect(WindowHandlers.pageOnlyCardRoute("card.noSuchCard") == nil)
        #expect(WindowHandlers.pageOnlyCardRoute("appearance.theme") == nil)
    }
}
