import Foundation
import Testing
@testable import CmuxMobileModel

@MainActor @Suite struct QuietConnectionSettingsTests {
    @Test func staysOptInAndPersistsAcrossStoreRecreation() throws {
        let suite = "QuietConnectionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.quietConnections)
        settings.quietConnections = true
        #expect(defaults.bool(forKey: "cmuxMobile.settings.quietConnections"))
        #expect(SettingsStore(defaults: defaults).quietConnections)
        settings.quietConnections = false
        #expect(!SettingsStore(defaults: defaults).quietConnections)
    }
}
