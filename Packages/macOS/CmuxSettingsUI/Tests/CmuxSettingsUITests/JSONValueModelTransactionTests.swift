import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

/// Exercises the same validated model mode used by ComputerUseSection.
@MainActor
@Suite struct JSONValueModelTransactionTests {
    @Test func userChoiceThroughModelConflictsWithPresetUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let store = JSONConfigStore(fileURL: file)
        let key = SettingCatalog().computerUse.showInMenuBar
        let receipt = try await store.setWithReceipt(false, for: key)
        let model = JSONValueModel(store: store, key: key, errorLog: SettingsErrorLog(), validateMutations: true)
        model.set(true)
        var attempts = 0
        while !store.snapshotValue(for: key), attempts < 100_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(store.snapshotValue(for: key))
        do { _ = try await store.undo(receipt); Issue.record("undo erased model choice") }
        catch JSONConfigMutationError.undoConflict { }
    }

    @Test func validatedModelWritesPastUnrelatedPreExistingIssues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        // A key from a newer build and an invalid value the toggle doesn't own.
        try Data(#"{"futureSetting":true,"app":{"appearance":"invalid"}}"#.utf8).write(to: file)
        let store = JSONConfigStore(fileURL: file)
        let key = SettingCatalog().computerUse.showInMenuBar
        let errors = SettingsErrorLog()
        let model = JSONValueModel(store: store, key: key, errorLog: errors, validateMutations: true)
        model.set(false)
        var attempts = 0
        while store.snapshotValue(for: key), errors.entries.isEmpty, attempts < 100_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(errors.entries.isEmpty)
        #expect(store.snapshotValue(for: key) == false)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("futureSetting"))
        #expect(written.contains(#""invalid""#))
    }

    @Test func validatedModelRefusesAnIssueItIntroduces() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let original = Data(#"{"futureSetting":true}"#.utf8)
        try original.write(to: file)
        let errors = SettingsErrorLog()
        // A string where the schema requires a boolean is an issue this write creates.
        let mistyped = JSONKey<String>(id: "computerUse.showInMenuBar", defaultValue: "")
        let model = JSONValueModel(store: JSONConfigStore(fileURL: file), key: mistyped,
                                   errorLog: errors, validateMutations: true)
        model.set("yes")
        var attempts = 0
        while errors.entries.isEmpty, attempts < 100_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(errors.entries.count == 1)
        let message = errors.entries.first?.message ?? ""
        #expect(message.contains("$.computerUse.showInMenuBar"))
        #expect(!message.contains("$.futureSetting"))
        #expect(try Data(contentsOf: file) == original)
    }
}
