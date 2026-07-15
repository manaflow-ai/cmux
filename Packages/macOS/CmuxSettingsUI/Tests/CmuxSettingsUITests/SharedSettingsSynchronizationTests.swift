import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite("Shared Settings synchronization")
struct SharedSettingsSynchronizationTests {
    @Test func twoMountedModelsConvergeThroughTheRuntimeStore() async {
        let suiteName = "shared-settings-sync-\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().betaFeatures.extensions
        let first = DefaultsValueModel(store: store, key: key)
        let second = DefaultsValueModel(store: store, key: key)
        first.startObserving()
        second.startObserving()

        await waitUntil { first.revision > 0 && second.revision > 0 }
        first.set(true)
        await waitUntil { second.current }

        #expect(first.current)
        #expect(second.current)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }
}
