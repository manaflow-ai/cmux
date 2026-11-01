import Foundation
import Testing
@testable import CmuxSettings

@Suite("ClaudeAccountAutoSwitchSetting")
struct ClaudeAccountAutoSwitchSettingTests {
    @Test func defaultsOffAndRoundTrips() async {
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!)
        let key = SettingCatalog().automation.claudeAccountAutoSwitch
        #expect(key.id == "automation.claudeAccountAutoSwitch")
        #expect(key.userDefaultsKey == "claudeAccountAutoSwitchEnabled")
        // Switching accounts is opt-in: a fresh store must read false.
        let unset = await store.value(for: key)
        #expect(unset == false)
        await store.set(true, for: key)
        let enabled = await store.value(for: key)
        #expect(enabled == true)
        await store.reset(key)
        let reset = await store.value(for: key)
        #expect(reset == false)
    }
}
