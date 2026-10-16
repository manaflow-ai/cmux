import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSettings

struct AccentColorSettingTests {
    @Test func catalogKeyStoresTheModeTheResolverReads() throws {
        let suite = "AccentColorSettingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = AppCatalogSection().accentColor

        #expect(key.id == "app.accentColor")
        #expect(key.userDefaultsKey == CmuxAccentColorMode.userDefaultsKey)
        #expect(key.defaultValue == .cmux)

        let client = UserDefaultsSettingsClient(defaults: defaults)
        for mode in CmuxAccentColorMode.allCases {
            client.set(mode, for: key)
            #expect(CmuxAccentColorMode.stored(in: defaults) == mode)
            #expect(client.value(for: key) == mode)
        }
    }
}
