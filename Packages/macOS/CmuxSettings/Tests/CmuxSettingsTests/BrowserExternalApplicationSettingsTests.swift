import Foundation
import CmuxSettings
import Testing

@Suite("Browser external application settings")
struct BrowserExternalApplicationSettingsTests {
    @Test("empty and whitespace values use the system default")
    func emptyValuesUseSystemDefault() {
        let suiteName = "cmux.browser-external-application-tests.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = BrowserExternalApplicationSettings(defaults: defaults)

        #expect(settings.applicationIdentifier == nil)

        defaults.set("  \n  ", forKey: BrowserExternalApplicationSettings.userDefaultsKey)
        #expect(settings.applicationIdentifier == nil)
    }

    @Test("trims a configured application identifier")
    func trimsConfiguredIdentifier() {
        let suiteName = "cmux.browser-external-application-tests.trimming.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("  com.google.Chrome  ", forKey: BrowserExternalApplicationSettings.userDefaultsKey)

        #expect(
            BrowserExternalApplicationSettings(defaults: defaults).applicationIdentifier == "com.google.Chrome"
        )
    }
}
