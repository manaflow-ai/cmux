import Foundation
import Testing
@testable import CmuxSettings

private func makePiScratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "cmux.tests.pi.\(UUID().uuidString)")!
}

@Suite("Pi agent integration settings")
struct PiAgentIntegrationSettingsStoreTests {
    @Test func defaultsEnableHooks() {
        let store = AgentIntegrationSettingsStore(defaults: makePiScratchDefaults())
        #expect(store.piHooksEnabled)
    }

    @Test func readsLegacyHookOverride() {
        let defaults = makePiScratchDefaults()
        defaults.set(false, forKey: "piHooksEnabled")
        let store = AgentIntegrationSettingsStore(defaults: defaults)
        #expect(!store.piHooksEnabled)
    }
}
