@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The unset window-opacity slider reads the opacity the window's theme
/// scope resolved (the app scope with no window open), never the app
/// theme store directly (check-theme-scope rule 3).
@MainActor
@Suite(.serialized)
struct SettingsDerivedOpacityTests {
    @Test func theOpacitySliderDefaultsToTheScopesOpacity() {
        let services = ActionBindingCoverageTests.boundServices()
        let host = SettingsWindowService(services: services)
        let scope = services.windows.active?.themeScope ?? .app
        #expect(host.derivedNumber(at: WindowBackgroundSetting.opacityPath) == scope.input.backgroundOpacity)
        #expect(host.derivedNumber(at: ["appearance", "density"]) == nil)
        withExtendedLifetime(services) {}
    }
}
