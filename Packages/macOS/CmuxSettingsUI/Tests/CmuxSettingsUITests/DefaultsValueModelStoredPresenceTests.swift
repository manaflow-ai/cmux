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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = model.set(true, afterCommit: { continuation.resume() })
            // Optimistic: explicit before the async write lands.
            #expect(model.hasStoredValue == true)
        }
        #expect(defaults.object(forKey: key.userDefaultsKey) as? Bool == true)
        #expect(model.hasStoredValue == true)

        _ = model.reset()
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
}
