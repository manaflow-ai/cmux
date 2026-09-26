import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// `hasStoredValue` lets Settings resolve layered defaults such as
/// `sidebar.density`: a toggle the user just flipped must count as explicit
/// immediately, before the async store write lands.
@MainActor
@Suite
struct DefaultsValueModelStoredPresenceTests {
    @Test func setMarksTheValueStoredBeforeTheWriteLands() async {
        let suiteName = "defaults-value-model-stored-presence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let key = SettingCatalog().sidebar.showPorts
        let model = DefaultsValueModel(store: store, key: key)

        #expect(model.hasStoredValue == false)

        _ = model.set(true)
        #expect(model.hasStoredValue == true)
        #expect(await waitUntil { await store.value(for: key) == true && defaults.object(forKey: key.userDefaultsKey) != nil })
        #expect(model.hasStoredValue == true)

        _ = model.reset()
        #expect(model.hasStoredValue == false)
        #expect(await waitUntil { defaults.object(forKey: key.userDefaultsKey) == nil })
        #expect(model.hasStoredValue == false)
    }

    @Test func seedsPresenceFromStorage() {
        let suiteName = "defaults-value-model-stored-presence-seed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().sidebar.showLog
        defaults.set(false, forKey: key.userDefaultsKey)

        let model = DefaultsValueModel(store: UserDefaultsSettingsStore(defaults: defaults), key: key)

        #expect(model.hasStoredValue == true)
        #expect(model.current == false)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}
