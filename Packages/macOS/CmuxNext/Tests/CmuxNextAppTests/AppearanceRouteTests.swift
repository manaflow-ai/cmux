import CmuxNextSettingsWindow
import Testing

/// Settings > Appearance's routes (one settings area, David Beyer 2026-11-20: Personalization was a
/// second page for the same choices). Personalization… opens Appearance, and Change Background…
/// opens it on the background picker with a route that is new at each request, because the host
/// opens a route only when it differs from the last one and the person may have scrolled since.
struct AppearanceRouteTests {
    @Test func personalizationOpensAppearance() {
        #expect(SettingsDeepLink.appearanceRoute() == "#/settings/appearance")
    }

    @Test func changeBackgroundIsANewRouteOnTheBackgroundPickerEachTime() {
        let first = SettingsDeepLink.appearanceRoute(background: true, workspace: "ws 1", open: 1)
        #expect(first == "#/settings/appearance?focus=appearance.background&open=1&workspace=ws%201")
        let again = SettingsDeepLink.appearanceRoute(background: true, workspace: "ws 1", open: 2)
        #expect(again != first)
        #expect(SettingsDeepLink.appearanceRoute(background: true) != SettingsDeepLink.appearanceRoute(background: true))
    }
}
