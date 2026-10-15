import CmuxSettings
import Foundation
import Testing
import CmuxBrowser

@Suite
struct BrowserEngineSettingTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "BrowserEngineSettingTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func unsetSettingIsWebKit() {
        #expect(BrowserEngineKind.configured(defaults: makeDefaults()) == .webkit)
        #expect(SettingCatalog().browser.engine.defaultValue == .webkit)
    }

    @Test func storedChromiumIsChromium() {
        let defaults = makeDefaults()
        defaults.set("chromium", forKey: SettingCatalog().browser.engine.userDefaultsKey)
        #expect(BrowserEngineKind.configured(defaults: defaults) == .chromium)
    }

    @Test func unknownStoredValueIsWebKit() {
        let defaults = makeDefaults()
        defaults.set("gecko", forKey: SettingCatalog().browser.engine.userDefaultsKey)
        #expect(BrowserEngineKind.configured(defaults: defaults) == .webkit)
    }

    @Test func settingValuesMatchEngineRawValues() {
        #expect(BrowserEngineSetting.allCases.map(\.rawValue) == BrowserEngineKind.allCases.map(\.rawValue))
        for setting in BrowserEngineSetting.allCases {
            #expect(BrowserEngineKind(setting: setting).rawValue == setting.rawValue)
        }
    }
}
