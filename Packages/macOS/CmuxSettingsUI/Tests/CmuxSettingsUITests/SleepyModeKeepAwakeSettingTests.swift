import Foundation
import Testing

@testable import CmuxSettingsUI

/// Persistence contract for the Amphetamine Mode toggle
/// (`keepAwakeWhileAgentsActive`): off by default, survives a store reload, and
/// writes under the expected UserDefaults key. Isolated `UserDefaults` per test.
@MainActor
@Suite
struct SleepyModeKeepAwakeSettingTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sleepy-keep-awake-\(UUID().uuidString)")!
    }

    @Test func defaultsToOff() {
        let store = SleepyModeSettingsStore(defaults: isolatedDefaults())
        #expect(store.keepAwakeWhileAgentsActive == false)
    }

    @Test func persistsAcrossStoreReload() {
        let defaults = isolatedDefaults()
        SleepyModeSettingsStore(defaults: defaults).keepAwakeWhileAgentsActive = true
        // A fresh store reading the same defaults must observe the saved value.
        let reloaded = SleepyModeSettingsStore(defaults: defaults)
        #expect(reloaded.keepAwakeWhileAgentsActive == true)
    }

    @Test func writesUnderExpectedKey() {
        let defaults = isolatedDefaults()
        let store = SleepyModeSettingsStore(defaults: defaults)
        store.keepAwakeWhileAgentsActive = true
        #expect(defaults.bool(forKey: SleepyModeDefaultsKeys.keepAwakeWhileAgentsActive) == true)
    }

    @Test func togglingOffPersistsFalse() {
        let defaults = isolatedDefaults()
        let store = SleepyModeSettingsStore(defaults: defaults)
        store.keepAwakeWhileAgentsActive = true
        store.keepAwakeWhileAgentsActive = false
        #expect(SleepyModeSettingsStore(defaults: defaults).keepAwakeWhileAgentsActive == false)
    }
}
