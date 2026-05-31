import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

@Suite("FileExtensionOpenersValueModel")
struct FileExtensionOpenersValueModelTests {
    @Test func readsEffectiveOpenersFromPartialStoredMap() async throws {
        let suiteName = "cmux.fileExtensionOpeners.ui.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        defaults.set(["css": "cmuxPreview"], forKey: FileExtensionOpenBehaviorSettings.key)
        let store = UserDefaultsSettingsStore(defaults: defaults)

        let model = await FileExtensionOpenersValueModel(store: store)
        await model.refresh()
        let current = await model.current
        #expect(current["html"] == .cmuxBrowser)
        #expect(current["htm"] == .cmuxBrowser)
        #expect(current["css"] == .cmuxPreview)
    }

    @Test func setPrunesDefaultValuesAndKeepsBuiltInAutomaticOverride() async throws {
        let suiteName = "cmux.fileExtensionOpeners.ui.set.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSettingsStore(defaults: defaults)

        let model = await FileExtensionOpenersValueModel(store: store)
        await model.setAndRefresh(["html": .automatic, "htm": .cmuxBrowser, "css": .cmuxBrowser])

        let current = await model.current
        #expect(current["html"] == .automatic)
        #expect(current["htm"] == .cmuxBrowser)
        #expect(current["css"] == .cmuxBrowser)
    }
}
