import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream cross-process clear")
struct WorkstreamClearCrossProcessTests {
    @Test("An app writer reopens the journal after another owner clears it")
    func appWriterReopensAfterExternalClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let appPersistence = WorkstreamPersistence(fileURL: url)
        let cliPersistence = WorkstreamPersistence(fileURL: url)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await appPersistence.append(WorkstreamItem(
            workstreamId: "before-clear", source: .claude, kind: .sessionStart,
            createdAt: timestamp, payload: .sessionStart
        ))
        try await cliPersistence.clear()
        try await appPersistence.append(WorkstreamItem(
            workstreamId: "after-clear", source: .claude, kind: .sessionStart,
            createdAt: timestamp, payload: .sessionStart
        ))

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await WorkstreamPersistence(fileURL: url).loadRecent(limit: 10).map(\.workstreamId) == ["after-clear"])
    }
}
