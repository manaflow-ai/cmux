import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct ShortcutListLegacyOverrideTests {
    @Test func settingsDisplaysLegacyOverrideUsedByRuntime() throws {
        let suiteName = "shortcut-list-legacy-override-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyShortcut = StoredShortcut(first: ShortcutStroke(
            key: "]",
            command: true,
            shift: true
        ))
        defaults.set(
            legacyShortcut.encodeForUserDefaults(),
            forKey: "shortcut.nextSidebarTab"
        )

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-list-legacy-override-\(UUID().uuidString).json")
        let model = ShortcutListModel(
            jsonStore: JSONConfigStore(fileURL: configURL),
            userDefaultsStore: UserDefaultsSettingsStore(defaults: defaults),
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )

        #expect(ShortcutAction.nextSidebarTab.defaultShortcut != legacyShortcut)
        #expect(model.effective(for: .nextSidebarTab) == legacyShortcut)
    }
}
