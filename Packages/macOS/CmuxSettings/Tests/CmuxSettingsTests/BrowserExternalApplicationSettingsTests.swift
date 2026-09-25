import Foundation
import Testing

@Suite("Browser external application settings")
struct BrowserExternalApplicationSettingsTests {
    @Test("empty and whitespace values use the system default")
    func emptyValuesUseSystemDefault() {
        let defaults = UserDefaults(suiteName: "cmux.browser-external-application-tests")!
        defaults.removePersistentDomain(forName: "cmux.browser-external-application-tests")
        let settings = BrowserExternalApplicationSettings(defaults: defaults)

        #expect(settings.applicationIdentifier == nil)

        defaults.set("  \n  ", forKey: BrowserExternalApplicationSettings.userDefaultsKey)
        #expect(settings.applicationIdentifier == nil)
    }

    @Test("trims a configured application identifier")
    func trimsConfiguredIdentifier() {
        let defaults = UserDefaults(suiteName: "cmux.browser-external-application-tests")!
        defaults.removePersistentDomain(forName: "cmux.browser-external-application-tests")
        defaults.set("  com.google.Chrome  ", forKey: BrowserExternalApplicationSettings.userDefaultsKey)

        #expect(
            BrowserExternalApplicationSettings(defaults: defaults).applicationIdentifier == "com.google.Chrome"
        )
    }
}
