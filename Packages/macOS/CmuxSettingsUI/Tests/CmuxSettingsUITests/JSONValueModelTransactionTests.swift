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

    @Test func validatedModelSurfacesFullCandidateRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        let original = Data(#"{"app":{"appearance":"invalid"}}"#.utf8)
        try original.write(to: file)
        let errors = SettingsErrorLog()
        let model = JSONValueModel(store: JSONConfigStore(fileURL: file), key: SettingCatalog().computerUse.showInMenuBar,
                                   errorLog: errors, validateMutations: true)
        model.set(false)
        var attempts = 0
        while errors.entries.isEmpty, attempts < 100_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(errors.entries.count == 1)
        #expect(errors.entries.first?.message.contains("$.app.appearance") == true)
        #expect(try Data(contentsOf: file) == original)
    }
}
