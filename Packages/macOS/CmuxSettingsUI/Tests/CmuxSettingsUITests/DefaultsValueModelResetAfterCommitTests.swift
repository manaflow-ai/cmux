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
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        setupDefaults.set("#ABCDEF", forKey: key.userDefaultsKey)

        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let model = DefaultsValueModel(store: store, key: key)

        await confirmation("afterCommit runs after reset") { afterCommit in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                model.reset(afterCommit: {
                    afterCommit()
                    continuation.resume()
                })
            }
        }

        #expect(await store.value(for: key) == key.defaultValue)
    }
}
