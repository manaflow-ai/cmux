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

    @Test func independentCachedStoresPreserveDisjointEdits() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = JSONConfigStore(fileURL: file)
        let second = JSONConfigStore(fileURL: file)
        _ = await first.value(for: appearance)
        _ = await second.value(for: badge)
        try await first.set("dark", for: appearance)
        try await second.set(false, for: badge)
        let fresh = JSONConfigStore(fileURL: file)
        #expect(await fresh.value(for: appearance) == "dark")
        #expect(await fresh.value(for: badge) == false)
    }

    @Test func externalEditBeforeWatcherInvalidationSurvives() async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JSONConfigStore(fileURL: file)
        _ = await store.value(for: appearance)
        // No subscription: deliberately no watcher invalidation is available.
        try Data(#"{"app":{"appearance":"light"}}"#.utf8).write(to: file, options: .atomic)
        try await store.set(false, for: badge)
        #expect(store.snapshotValue(for: appearance) == "light")
    }

    /// Pause the production helper after its read and before publication, then write
    /// through the actual GUI store. The validator seam is gated, not simulated I/O.
    @Test(arguments: [false, true])
    func helperPreparedWriteCannotEraseGUIEdit(sameKey: Bool) async throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent("skills/cmux-settings/scripts/cmux-settings")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", #"""
import argparse, importlib.machinery, importlib.util, pathlib, sys
p = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(p.parent))
loader = importlib.machinery.SourceFileLoader('helper', str(p))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
def gate(*args):
    print('prepared', flush=True)
    assert sys.stdin.readline().strip() == 'commit'
    return True
m.validate_candidate = gate
raise SystemExit(m.cmd_set(argparse.Namespace(file=sys.argv[2], key='app.appearance', value='dark', scope='global')))
"""#, helper.path, file.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        // Read exactly the readiness line; no scheduler delays or polling.
        var line = Data()
        while !line.contains(10) {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            try #require(!byte.isEmpty, "helper exited before reaching the barrier")
            line.append(byte)
        }
        #expect(String(decoding: line, as: UTF8.self) == "prepared\n")
        let gui = JSONConfigStore(fileURL: file)
        var refused = false
        do {
            if sameKey { try await gui.set("light", for: appearance) }
            else { try await gui.set(false, for: badge) }
        } catch JSONConfigMutationError.busy { refused = true }
        try input.fileHandleForWriting.write(contentsOf: Data("commit\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        if !refused {
            if sameKey { #expect(gui.snapshotValue(for: appearance) == "light") }
            else { #expect(gui.snapshotValue(for: badge) == false) }
        }
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
