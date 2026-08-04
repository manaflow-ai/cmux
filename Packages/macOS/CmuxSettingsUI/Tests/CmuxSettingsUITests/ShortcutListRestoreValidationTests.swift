import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct ShortcutListRestoreValidationTests {
    @Test func restorePreservesSupportedLegacyBareSpaceBinding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shortcut-list-restore-bare-space-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let shortcut = StoredShortcut(first: ShortcutStroke(key: "space"))
        try await store.set(
            [ShortcutAction.openSettings.rawValue: shortcut],
            for: catalog.shortcuts.bindings
        )
        let model = ShortcutListModel(
            jsonStore: store,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )
        model.startObserving()
        await spin {
            model.effective(for: .openSettings) == shortcut
        }

        await model.clearOrRestore(for: .openSettings)
        await spin {
            model.bindings[ShortcutAction.openSettings.rawValue]?.isUnbound == true
        }
        #expect(model.restoreShortcuts[ShortcutAction.openSettings.rawValue] == shortcut)

        await model.clearOrRestore(for: .openSettings)
        await spin {
            model.bindings[ShortcutAction.openSettings.rawValue] == shortcut
        }

        #expect(model.bindings[ShortcutAction.openSettings.rawValue] == shortcut)
        #expect(model.effective(for: .openSettings) == shortcut)
        #expect(model.restoreShortcuts[ShortcutAction.openSettings.rawValue] == nil)
        #expect(!model.bareKeyRejections.contains(ShortcutAction.openSettings.rawValue))
    }

    @Test func restoreRejectsNewShowHideConflictAndKeepsCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shortcut-list-restore-validation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let shortcut = StoredShortcut(first: ShortcutStroke(
            key: "g",
            command: true,
            option: true,
            control: true
        ))
        try await store.set(
            [ShortcutAction.globalSearch.rawValue: shortcut],
            for: catalog.shortcuts.bindings
        )
        let model = ShortcutListModel(
            jsonStore: store,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )
        model.startObserving()
        await spin {
            model.effective(for: .globalSearch) == shortcut
        }

        await model.clearOrRestore(for: .globalSearch)
        await spin {
            model.bindings[ShortcutAction.globalSearch.rawValue]?.isUnbound == true
        }
        #expect(model.restoreShortcuts[ShortcutAction.globalSearch.rawValue] == shortcut)
        #expect(model.effective(for: .globalSearch) == nil)

        await model.assign(stroke: shortcut.first, to: .showHideAllWindows)
        await spin {
            model.bindings[ShortcutAction.showHideAllWindows.rawValue] == shortcut
        }
        #expect(model.effective(for: .showHideAllWindows) == shortcut)

        await model.clearOrRestore(for: .globalSearch)

        #expect(
            model.conflictRejections[ShortcutAction.globalSearch.rawValue]
                == .showHideAllWindows
        )
        #expect(model.effective(for: .globalSearch) == nil)
        #expect(model.restoreShortcuts[ShortcutAction.globalSearch.rawValue] == shortcut)
        #expect(
            await store.value(for: catalog.shortcuts.bindings)[
                ShortcutAction.globalSearch.rawValue
            ]?.isUnbound == true
        )
    }

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }
}
