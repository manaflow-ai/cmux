import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The app never writes cmux-next.json: every write is one `settings.edit` to the daemon's settings
/// owner (`SettingsFileWriter`), and with no writer a write is refused and nothing is written
/// (plans/cmux-next/settings-react.md section 1: "nothing queues").
@MainActor @Suite(.serialized) struct SettingsWriterTests {
    /// Records each write's edits and applies none.
    actor Recording: SettingsFileWriter {
        var writes: [[SettingsFileEdit]] = []
        func edit(_ edits: [SettingsFileEdit], file: URL) async throws -> [Int] {
            writes.append(edits)
            return Array(edits.indices)
        }
    }

    func file(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-settings-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux-next.json")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aWriteWithNoWriterIsRefusedAndWritesNothing() async throws {
        let url = try file("{\n  // mine\n  \"appearance\": {}\n}\n")
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        await #expect(throws: SettingsWriterDisconnected.self) {
            try await settings.set(.string("bottom"), at: ["tabs", "barPosition"])
        }
        await #expect(throws: SettingsWriterDisconnected.self) {
            try await settings.file.remove(["appearance"])
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\n  // mine\n  \"appearance\": {}\n}\n")
    }

    @Test func writesGoToTheWriterAsOneEditEachInCallOrder() async throws {
        let url = try file("{}\n")
        let writer = Recording()
        let file = CmuxConfigFile(url: url, writer: writer)
        try await file.set(.number(1), at: ["a", "b"])
        try await file.apply([(path: ["c"], value: .bool(true)), (path: ["d"], value: nil)])
        _ = try await file.setUnset([(path: ["e"], value: .null)])
        #expect(await writer.writes == [
            [.set(["a", "b"], .number(1))],
            [.set(["c"], .bool(true)), .reset(["d"])],
            [.setUnset(["e"], .null)],
        ])
        // The app wrote nothing itself.
        #expect(try String(contentsOf: url, encoding: .utf8) == "{}\n")
    }

    @Test func removePruningIsOnePublishThatDropsOnlyStillEmptyParents() async throws {
        let url = try file("{}\n")
        let writer = Recording()
        let settings = SettingsController(writer: writer, registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        try await settings.removePruning(["a", "b", "c"])
        #expect(await writer.writes == [[
            .reset(["a", "b", "c"]),
            .resetUnchanged(["a", "b"], .object([:])),
            .resetUnchanged(["a"], .object([:])),
        ]])
    }
}
