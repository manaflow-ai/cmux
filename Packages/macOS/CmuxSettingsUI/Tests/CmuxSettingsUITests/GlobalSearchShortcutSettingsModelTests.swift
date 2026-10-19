import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite(.serialized)
final class GlobalSearchShortcutSettingsModelTests {
    @Test func distinctChordSuffixesCanShareAPrefix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let model = ShortcutListModel(
            jsonStore: store,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )
        let prefix = ShortcutStroke(
            key: "j",
            command: true,
            shift: true,
            option: true,
            control: true
        )
        let settingsChord = StoredShortcut(
            first: prefix,
            second: ShortcutStroke(key: "p")
        )
        let searchChord = StoredShortcut(
            first: prefix,
            second: ShortcutStroke(key: "f")
        )

        await model.assignChord(settingsChord, to: .openSettings)
        await model.assignChord(searchChord, to: .globalSearch)

        let bindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(bindings[ShortcutAction.openSettings.rawValue] == settingsChord)
        #expect(bindings[ShortcutAction.globalSearch.rawValue] == searchChord)
        #expect(model.conflictRejections[ShortcutAction.globalSearch.rawValue] == nil)
    }

    @Test func persistedMediaKeyGlobalSearchBindingIsNotEffective() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let mediaShortcut = StoredShortcut(
            first: ShortcutStroke(key: "media.playPause", command: true)
        )
        let observationSentinel = StoredShortcut(
            first: ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true)
        )
        try await store.set(
            [
                ShortcutAction.globalSearch.rawValue: mediaShortcut,
                ShortcutAction.openSettings.rawValue: observationSentinel,
            ],
            for: catalog.shortcuts.bindings
        )

        let model = ShortcutListModel(
            jsonStore: store,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )
        model.startObserving()
        await spin {
            model.bindings[ShortcutAction.openSettings.rawValue] == observationSentinel
        }

        #expect(model.bindings[ShortcutAction.globalSearch.rawValue] == mediaShortcut)
        #expect(model.effective(for: .globalSearch) == ShortcutAction.globalSearch.defaultShortcut)
    }

    @Test func mediaKeyGlobalSearchBindingCannotBeRestored() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let model = ShortcutListModel(
            jsonStore: store,
            catalog: catalog,
            errorLog: SettingsErrorLog()
        )
        let mediaShortcut = StoredShortcut(
            first: ShortcutStroke(key: "j", command: true),
            second: ShortcutStroke(key: "media.playPause")
        )

        await model.restoreBinding(mediaShortcut, for: .globalSearch)

        let bindings = await store.value(for: catalog.shortcuts.bindings)
        #expect(bindings[ShortcutAction.globalSearch.rawValue] == nil)
        #expect(
            model.validationMessage(for: .globalSearch)
                == String(
                    localized: "shortcut.recorder.error.reservedBySystem",
                    defaultValue: "This keystroke is reserved by macOS."
                )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func spin(until condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < 100_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(condition(), "spin(until:) timed out after 100,000 yields")
    }
}
