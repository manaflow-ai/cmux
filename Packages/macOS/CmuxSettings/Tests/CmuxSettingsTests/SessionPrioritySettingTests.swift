import Foundation
import Testing
@testable import CmuxSettings

@Suite("SessionPrioritySetting")
struct SessionPrioritySettingTests {
    @Test func defaultsOffAndRoundTrips() async {
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!)
        let catalog = SettingCatalog().automation
        let enabledKey = catalog.sessionPriority
        let urgentKey = catalog.sessionPriorityUrgentCount
        let matrixKey = catalog.sessionPriorityMatrix
        #expect(enabledKey.id == "automation.sessionPriority.enabled")
        #expect(enabledKey.userDefaultsKey == "sessionPriorityEnabled")
        #expect(urgentKey.id == "automation.sessionPriority.urgentCount")
        #expect(urgentKey.userDefaultsKey == "sessionPriorityUrgentCount")
        #expect(matrixKey.id == "automation.sessionPriority.matrix")
        #expect(matrixKey.userDefaultsKey == "sessionPriorityMatrix")
        // Opt-in: a fresh store must read off, three urgent sessions, no matrix override.
        #expect(await store.value(for: enabledKey) == false)
        #expect(await store.value(for: urgentKey) == 3)
        #expect(await store.value(for: matrixKey) == "")
        await store.set(true, for: enabledKey)
        #expect(await store.value(for: enabledKey) == true)
        await store.reset(enabledKey)
        #expect(await store.value(for: enabledKey) == false)
    }
}
