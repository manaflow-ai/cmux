import Foundation
import Testing
@testable import CmuxSettings

private func makeAgentProcessNamesScratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "cmux.tests.agentProcessNames.\(UUID().uuidString)")!
}

@Suite("Agent process names setting")
struct AgentProcessNamesSettingsStoreTests {
    @Test func defaultsOn() {
        let store = AgentIntegrationSettingsStore(defaults: makeAgentProcessNamesScratchDefaults())
        #expect(store.agentProcessNamesEnabled)
        #expect(SettingCatalog().automation.agentProcessNames.id == "automation.agentProcessNames")
    }

    @Test func readsStoredOptOut() {
        let defaults = makeAgentProcessNamesScratchDefaults()
        defaults.set(false, forKey: "agentProcessNamesEnabled")
        let store = AgentIntegrationSettingsStore(defaults: defaults)
        #expect(!store.agentProcessNamesEnabled)
    }
}
