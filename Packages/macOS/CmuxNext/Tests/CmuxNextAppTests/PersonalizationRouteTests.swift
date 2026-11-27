import CmuxNextSettingsWindow
import Testing

/// Settings > Personalization's routes (Leo 2026-11-07): Personalization… opens the page, and
/// Change Background… opens it on Background with a route that is new at each request, because the
/// host opens a route only when it differs from the last one and the person may have jumped since.
struct PersonalizationRouteTests {
    @Test func personalizationOpensThePage() {
        #expect(SettingsDeepLink.personalizationRoute() == "#/settings/personalization")
    }

    @Test func changeBackgroundIsANewRouteOnBackgroundEachTime() {
        let first = SettingsDeepLink.personalizationRoute(part: "background", workspace: "ws 1", open: 1)
        #expect(first == "#/settings/personalization?focus=personalization.background&open=1&workspace=ws%201")
        let again = SettingsDeepLink.personalizationRoute(part: "background", workspace: "ws 1", open: 2)
        #expect(again != first)
        #expect(SettingsDeepLink.personalizationRoute(part: "background") != SettingsDeepLink.personalizationRoute(part: "background"))
    }
}
