import Foundation
import Testing
@testable import CmuxSettings

@Suite("JSON config transactions")
struct JSONConfigTransactionTests {
    private let appearance = JSONKey<String>(id: "app.appearance", defaultValue: "system")
    private let badge = JSONKey<Bool>(id: "notifications.dockBadge", defaultValue: true)

    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("cmux.json")
        try Data("{\n // retain me\n \"app\": {\"appearance\": \"system\"}\n}\n".utf8).write(to: file)
        return file
    }

    @Test func undoPreservesNewerGUIChoiceAndUnrelatedEdits() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let key = SettingCatalog().computerUse.showInMenuBar
        let preset = JSONConfigStore(fileURL: file)
        let receipt = try await preset.setWithReceipt(false, for: key)
        let gui = JSONConfigStore(fileURL: file)
        _ = try await gui.setWithReceipt(true, for: key)
        try await gui.set(false, for: badge)
        let beforeUndo = try Data(contentsOf: file)
        do {
            _ = try await preset.undo(receipt)
            Issue.record("stale undo accepted")
        } catch JSONConfigMutationError.undoConflict(let path, let expected, let current, let restore) {
            #expect(path == key.id)
            #expect(expected == Data("false".utf8))
            #expect(current == Data("true".utf8))
            #expect(restore == nil)
        }
        #expect(try Data(contentsOf: file) == beforeUndo)
        #expect(gui.snapshotValue(for: key))
        #expect(gui.snapshotValue(for: badge) == false)
    }

    @Test func undoRestoresAbsenceAndExplicitPinAcrossDefaultChanges() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        let key = SettingCatalog().computerUse.showInMenuBar
        let install = try await store.setWithReceipt(false, for: key)
        try await store.set(false, for: badge)
        _ = try await store.undo(install)
        let changedDefault = JSONKey<Bool>(id: key.id, defaultValue: false)
        #expect(store.snapshotValue(for: changedDefault) == false) // absent inherits
        let pin = try await store.setWithReceipt(true, for: key)
        #expect(pin.before == nil)
        let reset = try await store.resetWithReceipt(key)
        _ = try await store.undo(reset)
        #expect(store.snapshotValue(for: changedDefault) == true) // explicit pin remains
        #expect(store.snapshotValue(for: badge) == false)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("// retain me"))
    }

    @Test func validatedMutationRejectsCandidateAndRetainsLegacyContract() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        let before = try Data(contentsOf: file)
        do {
            _ = try await store.setWithReceipt("invalid", for: appearance)
            Issue.record("invalid semantic candidate accepted")
        } catch JSONConfigMutationError.invalidCandidate(let issues) {
            #expect(issues.contains { $0.path == "$.app.appearance" })
        }
        #expect(try Data(contentsOf: file) == before)
        // The canonical schema includes this real legacy catalog key so a
        // validated Computer Use write cannot reject an otherwise valid file.
        let legacy = SettingCatalog().app.devWindowDisplay
        try await store.set("Fixture Display", for: legacy)
        #expect(store.snapshotValue(for: legacy) == "Fixture Display")
        let legacyBytes = try Data(contentsOf: file)
        _ = try await store.setWithReceipt(false, for: SettingCatalog().computerUse.showInMenuBar)
        #expect(store.snapshotValue(for: SettingCatalog().computerUse.showInMenuBar) == false)
        #expect(try Data(contentsOf: file) != legacyBytes)
        #expect(store.snapshotValue(for: legacy) == "Fixture Display")
    }

    @Test func undoRejectsRetargetedSymlink() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
        let other = file.deletingLastPathComponent().appendingPathComponent("other.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let store = JSONConfigStore(fileURL: link)
        let receipt = try await store.setWithReceipt("dark", for: appearance)
        try Data(contentsOf: file).write(to: other)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        let before = try Data(contentsOf: other)
        do { _ = try await store.undo(receipt); Issue.record("retargeted undo accepted") }
        catch JSONConfigMutationError.undoConflict { }
        #expect(try Data(contentsOf: other) == before)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
}
