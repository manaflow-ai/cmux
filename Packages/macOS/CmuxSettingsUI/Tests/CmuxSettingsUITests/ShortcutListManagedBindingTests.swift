import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite struct ShortcutListManagedBindingTests {
    @Test func invalidManagedShowHideDoesNotDisplayBuiltInShortcut() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shortcut-list-invalid-managed-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("cmux.json")
        try """
        {
          "shortcuts": {
            "bindings": {
              "showHideAllWindows": "j"
            }
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let model = ShortcutListModel(
            jsonStore: JSONConfigStore(fileURL: fileURL),
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )
        model.startObserving()

        await spin {
            model.effective(for: .showHideAllWindows) == nil
        }

        #expect(model.effective(for: .showHideAllWindows) == nil)
    }

    @Test func unrelatedWritePreservesMalformedManagedSibling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shortcut-list-preserves-malformed-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("cmux.json")
        try """
        {
          "shortcuts": {
            "bindings": {
              "showHideAllWindows": 42
            }
          }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let model = ShortcutListModel(
            jsonStore: JSONConfigStore(fileURL: fileURL),
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )
        model.startObserving()
        await spin {
            model.managedBindingActionIDs.contains(
                ShortcutAction.showHideAllWindows.rawValue
            )
        }

        await model.clearBinding(for: .globalSearch)

        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        let shortcuts = try #require(root["shortcuts"] as? [String: Any])
        let bindings = try #require(shortcuts["bindings"] as? [String: Any])
        #expect(bindings["showHideAllWindows"] as? Int == 42)
        #expect(
            StoredShortcut.decodeFromJSON(
                bindings["globalSearch"]
            )?.isUnbound == true
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
