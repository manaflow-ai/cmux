import Foundation
import Testing
@testable import CmuxSettings

private func makeLanguageScratchDefaults() -> (String, UserDefaults) {
    let suiteName = "cmux.tests.\(UUID().uuidString)"
    return (suiteName, UserDefaults(suiteName: suiteName)!)
}

private func makeLanguageSettingsStore(defaults: UserDefaults, suiteName: String) -> LanguageSettingsStore {
    LanguageSettingsStore(defaults: defaults)
}

@Suite("LanguageSettingsStore override ownership")
struct LanguageSettingsOverrideTests {
    @Test func systemSelectionPreservesForeignAppleLanguagesOverride() {
        let (suiteName, defaults) = makeLanguageScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeLanguageSettingsStore(defaults: defaults, suiteName: suiteName)

        defaults.set(["zh-Hant"], forKey: "AppleLanguages")
        store.applyLanguageOverride(.system)

        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String] == ["zh-Hant"])
    }

    @Test func systemSelectionPreservesManuallyReplacedOverride() {
        let (suiteName, defaults) = makeLanguageScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeLanguageSettingsStore(defaults: defaults, suiteName: suiteName)

        store.applyLanguageOverride(.zhHant)
        defaults.set(["fr"], forKey: "AppleLanguages")
        store.applyLanguageOverride(.system)

        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String] == ["fr"])
    }

}
