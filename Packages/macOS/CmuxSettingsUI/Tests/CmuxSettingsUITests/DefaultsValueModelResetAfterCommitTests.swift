import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct DefaultsValueModelResetAfterCommitTests {
    @Test func resetAfterCommitRunsAfterStoreReset() async {
        let suiteName = "defaults-value-model-reset-after-commit"
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let setupDefaults = UserDefaults(suiteName: suiteName)!
        setupDefaults.removePersistentDomain(forName: suiteName)
        setupDefaults.set("#ABCDEF", forKey: key.userDefaultsKey)

        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let model = DefaultsValueModel(store: store, key: key)
        var didRunAfterCommit = false

        model.reset(afterCommit: {
            didRunAfterCommit = true
        })

        var spins = 0
        while !didRunAfterCommit, spins < 100_000 {
            await Task.yield()
            spins += 1
        }

        #expect(didRunAfterCommit)
        #expect(await store.value(for: key) == key.defaultValue)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}
